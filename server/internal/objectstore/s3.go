package objectstore

import (
	"context"
	"errors"
	"fmt"
	"io"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// S3 是 S3 兼容对象存储的实现。自建时用 MinIO，换成阿里云 OSS、腾讯云 COS
// 这类兼容接口时只改 endpoint 与密钥（ADR-0016）。
type S3 struct {
	client *minio.Client
	bucket string
}

// S3Options 是连接对象存储需要的全部配置，来自环境变量。
type S3Options struct {
	// Endpoint 是 host[:port]，不带协议；UseSSL 决定用 https 还是 http。
	Endpoint  string
	Bucket    string
	AccessKey string
	SecretKey string
	Region    string
	UseSSL    bool
}

// NewS3 建立客户端。它不访问网络：连通性由 Ping 在就绪检查时确认。
func NewS3(opts S3Options) (*S3, error) {
	if opts.Endpoint == "" || opts.Bucket == "" || opts.AccessKey == "" || opts.SecretKey == "" {
		return nil, errors.New("objectstore: S3 需要 endpoint、bucket、access key 与 secret key")
	}
	client, err := minio.New(opts.Endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(opts.AccessKey, opts.SecretKey, ""),
		Secure: opts.UseSSL,
		Region: opts.Region,
	})
	if err != nil {
		return nil, fmt.Errorf("objectstore: 建 S3 客户端失败: %w", err)
	}
	return &S3{client: client, bucket: opts.Bucket}, nil
}

func (s *S3) Put(ctx context.Context, key string, data io.Reader, info Info) error {
	res, err := s.client.PutObject(ctx, s.bucket, key, data, info.Size, minio.PutObjectOptions{
		ContentType: info.ContentType,
	})
	if err != nil {
		return fmt.Errorf("objectstore: 上传失败: %w", err)
	}
	if res.Size != info.Size {
		return fmt.Errorf("objectstore: 上传了 %d 字节，与声明的 %d 不符", res.Size, info.Size)
	}
	return nil
}

func (s *S3) Open(ctx context.Context, key string) (io.ReadCloser, Info, error) {
	obj, err := s.client.GetObject(ctx, s.bucket, key, minio.GetObjectOptions{})
	if err != nil {
		return nil, Info{}, mapNotFound(err)
	}
	// GetObject 是惰性的，先取元数据才能在读取之前发现对象不存在。
	st, err := obj.Stat()
	if err != nil {
		_ = obj.Close()
		return nil, Info{}, mapNotFound(err)
	}
	return obj, Info{Size: st.Size, ContentType: st.ContentType}, nil
}

func (s *S3) Stat(ctx context.Context, key string) (Info, error) {
	st, err := s.client.StatObject(ctx, s.bucket, key, minio.StatObjectOptions{})
	if err != nil {
		return Info{}, mapNotFound(err)
	}
	return Info{Size: st.Size, ContentType: st.ContentType}, nil
}

func (s *S3) Remove(ctx context.Context, key string) error {
	if err := s.client.RemoveObject(ctx, s.bucket, key, minio.RemoveObjectOptions{}); err != nil {
		return fmt.Errorf("objectstore: 删除失败: %w", err)
	}
	return nil
}

// RemovePrefix 按前缀列出对象再逐个删除；删除账号时一次调用即可清完全部附件。
func (s *S3) RemovePrefix(ctx context.Context, prefix string) error {
	if prefix == "" {
		return errors.New("objectstore: 拒绝删除空前缀")
	}
	objs := s.client.ListObjects(ctx, s.bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true})
	for obj := range objs {
		if obj.Err != nil {
			return fmt.Errorf("objectstore: 列出前缀 %q 失败: %w", prefix, obj.Err)
		}
		if err := s.Remove(ctx, obj.Key); err != nil {
			return err
		}
	}
	return nil
}

func (s *S3) Ping(ctx context.Context) error {
	ok, err := s.client.BucketExists(ctx, s.bucket)
	if err != nil {
		return fmt.Errorf("objectstore: 对象存储不可达: %w", err)
	}
	if !ok {
		return fmt.Errorf("objectstore: bucket %q 不存在", s.bucket)
	}
	return nil
}

// mapNotFound 把对象存储的“没有这个键”统一成 ErrNotFound，其余的照原样返回。
func mapNotFound(err error) error {
	resp := minio.ToErrorResponse(err)
	if resp.Code == "NoSuchKey" || resp.Code == "NoSuchObject" || resp.Code == "NotFound" || resp.StatusCode == 404 {
		return ErrNotFound
	}
	return err
}
