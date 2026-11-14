package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/BUPT521/zhixin/server/internal/api"
	"github.com/BUPT521/zhixin/server/internal/httpx"
)

type requestKey struct{}
type requestBodyKey struct{}

type contract struct {
	legacy *http.ServeMux
}

func (c contract) serve(ctx context.Context, w http.ResponseWriter) {
	r := ctx.Value(requestKey{}).(*http.Request).WithContext(ctx)
	if raw, ok := ctx.Value(requestBodyKey{}).([]byte); ok {
		r.Body = io.NopCloser(bytes.NewReader(raw))
	}
	c.legacy.ServeHTTP(w, r)
}

type bufferedResponse struct {
	headers http.Header
	code    int
	body    bytes.Buffer
}

func (b *bufferedResponse) Header() http.Header  { return b.headers }
func (b *bufferedResponse) WriteHeader(code int) { b.code = code }
func (b *bufferedResponse) Write(p []byte) (int, error) {
	if b.code == 0 {
		b.code = http.StatusOK
	}
	return b.body.Write(p)
}

func (b *bufferedResponse) forward(w http.ResponseWriter) error {
	for key, values := range b.headers {
		w.Header()[key] = values
	}
	w.WriteHeader(b.code)
	_, err := b.body.WriteTo(w)
	return err
}

func jsonResponse[T any](c contract, ctx context.Context, success int) (T, *bufferedResponse) {
	response := &bufferedResponse{headers: make(http.Header)}
	c.serve(ctx, response)
	var result T
	if response.code != success {
		return result, response
	}
	if err := json.Unmarshal(response.body.Bytes(), &result); err != nil {
		response = &bufferedResponse{headers: make(http.Header)}
		httpx.WriteProblem(response, ctx.Value(requestKey{}).(*http.Request),
			http.StatusInternalServerError, httpx.CodeInternal, "")
		return result, response
	}
	return result, nil
}

type rawResponse struct {
	write func(http.ResponseWriter) error
}

func raw(c contract, ctx context.Context) rawResponse {
	return rawResponse{write: func(w http.ResponseWriter) error { c.serve(ctx, w); return nil }}
}

func buffered(response *bufferedResponse) rawResponse {
	return rawResponse{write: response.forward}
}

func contractHandler(mux, legacy *http.ServeMux, maxJSON, maxModel int64) {
	badRequest := func(w http.ResponseWriter, r *http.Request, err error) {
		var limit *http.MaxBytesError
		if errors.As(err, &limit) {
			httpx.WriteProblem(w, r, http.StatusRequestEntityTooLarge, httpx.CodePayloadTooLarge, "")
			return
		}
		httpx.WriteProblem(w, r, http.StatusBadRequest, httpx.CodeInvalidRequest, "invalid request parameters or body")
	}
	internalError := func(w http.ResponseWriter, r *http.Request, _ error) {
		httpx.WriteProblem(w, r, http.StatusInternalServerError, httpx.CodeInternal, "")
	}
	strict := api.NewStrictHandlerWithOptions(contract{legacy}, []api.StrictMiddlewareFunc{
		func(next api.StrictHandlerFunc, _ string) api.StrictHandlerFunc {
			return func(ctx context.Context, w http.ResponseWriter, r *http.Request, input any) (any, error) {
				return next(context.WithValue(ctx, requestKey{}, r), w, r, input)
			}
		},
	}, api.StrictHTTPServerOptions{
		RequestErrorHandlerFunc: badRequest, ResponseErrorHandlerFunc: internalError,
	})
	api.HandlerWithOptions(strict, api.StdHTTPServerOptions{
		BaseRouter: mux, ErrorHandlerFunc: badRequest,
		Middlewares: []api.MiddlewareFunc{func(next http.Handler) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				cap := maxJSON
				switch r.Pattern {
				case "POST /v1/sync/commits":
					cap *= 16
				case "POST /v1/llm/chat/completions":
					cap = maxModel
				case "POST /v1/auth/register", "POST /v1/auth/login", "POST /v1/auth/refresh":
				default:
					next.ServeHTTP(w, r)
					return
				}
				original := http.MaxBytesReader(w, r.Body, cap)
				defer original.Close()
				body, err := io.ReadAll(original)
				if err != nil {
					badRequest(w, r, err)
					return
				}
				r.Body = io.NopCloser(bytes.NewReader(body))
				next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), requestBodyKey{}, body)))
			})
		}},
	})
}

var _ api.StrictServerInterface = contract{}

func (c contract) GetReadyz(ctx context.Context, _ api.GetReadyzRequestObject) (api.GetReadyzResponseObject, error) {
	result, problem := jsonResponse[api.GetReadyz200JSONResponse](c, ctx, 200)
	if problem != nil {
		return getReadyzResponse{buffered(problem)}, nil
	}
	return result, nil
}

type getReadyzResponse struct{ rawResponse }

func (r getReadyzResponse) VisitGetReadyzResponse(w http.ResponseWriter) error { return r.write(w) }

func (c contract) PostV1AuthLogin(ctx context.Context, _ api.PostV1AuthLoginRequestObject) (api.PostV1AuthLoginResponseObject, error) {
	result, problem := jsonResponse[api.PostV1AuthLogin200JSONResponse](c, ctx, 200)
	if problem != nil {
		return postV1AuthLoginResponse{buffered(problem)}, nil
	}
	return result, nil
}

type postV1AuthLoginResponse struct{ rawResponse }

func (r postV1AuthLoginResponse) VisitPostV1AuthLoginResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) PostV1AuthRegister(ctx context.Context, _ api.PostV1AuthRegisterRequestObject) (api.PostV1AuthRegisterResponseObject, error) {
	result, problem := jsonResponse[api.PostV1AuthRegister201JSONResponse](c, ctx, 201)
	if problem != nil {
		return postV1AuthRegisterResponse{buffered(problem)}, nil
	}
	return result, nil
}

type postV1AuthRegisterResponse struct{ rawResponse }

func (r postV1AuthRegisterResponse) VisitPostV1AuthRegisterResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) PostV1AuthRefresh(ctx context.Context, _ api.PostV1AuthRefreshRequestObject) (api.PostV1AuthRefreshResponseObject, error) {
	result, problem := jsonResponse[api.PostV1AuthRefresh200JSONResponse](c, ctx, 200)
	if problem != nil {
		return postV1AuthRefreshResponse{buffered(problem)}, nil
	}
	return result, nil
}

type postV1AuthRefreshResponse struct{ rawResponse }

func (r postV1AuthRefreshResponse) VisitPostV1AuthRefreshResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) GetV1Me(ctx context.Context, _ api.GetV1MeRequestObject) (api.GetV1MeResponseObject, error) {
	result, problem := jsonResponse[api.GetV1Me200JSONResponse](c, ctx, 200)
	if problem != nil {
		return getV1MeResponse{buffered(problem)}, nil
	}
	return result, nil
}

type getV1MeResponse struct{ rawResponse }

func (r getV1MeResponse) VisitGetV1MeResponse(w http.ResponseWriter) error { return r.write(w) }

func (c contract) GetV1Backups(ctx context.Context, _ api.GetV1BackupsRequestObject) (api.GetV1BackupsResponseObject, error) {
	result, problem := jsonResponse[api.GetV1Backups200JSONResponse](c, ctx, 200)
	if problem != nil {
		return getV1BackupsResponse{buffered(problem)}, nil
	}
	return result, nil
}

type getV1BackupsResponse struct{ rawResponse }

func (r getV1BackupsResponse) VisitGetV1BackupsResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) PostV1Backups(ctx context.Context, _ api.PostV1BackupsRequestObject) (api.PostV1BackupsResponseObject, error) {
	result, problem := jsonResponse[api.PostV1Backups201JSONResponse](c, ctx, 201)
	if problem != nil {
		return postV1BackupsResponse{buffered(problem)}, nil
	}
	return result, nil
}

type postV1BackupsResponse struct{ rawResponse }

func (r postV1BackupsResponse) VisitPostV1BackupsResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) GetV1LlmQuota(ctx context.Context, _ api.GetV1LlmQuotaRequestObject) (api.GetV1LlmQuotaResponseObject, error) {
	result, problem := jsonResponse[api.GetV1LlmQuota200JSONResponse](c, ctx, 200)
	if problem != nil {
		return getV1LlmQuotaResponse{buffered(problem)}, nil
	}
	return result, nil
}

type getV1LlmQuotaResponse struct{ rawResponse }

func (r getV1LlmQuotaResponse) VisitGetV1LlmQuotaResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) GetV1SyncCommits(ctx context.Context, _ api.GetV1SyncCommitsRequestObject) (api.GetV1SyncCommitsResponseObject, error) {
	result, problem := jsonResponse[api.GetV1SyncCommits200JSONResponse](c, ctx, 200)
	if problem != nil {
		return getV1SyncCommitsResponse{buffered(problem)}, nil
	}
	return result, nil
}

type getV1SyncCommitsResponse struct{ rawResponse }

func (r getV1SyncCommitsResponse) VisitGetV1SyncCommitsResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) PostV1SyncCommits(ctx context.Context, _ api.PostV1SyncCommitsRequestObject) (api.PostV1SyncCommitsResponseObject, error) {
	result, problem := jsonResponse[api.PostV1SyncCommits200JSONResponse](c, ctx, 200)
	if problem != nil {
		return postV1SyncCommitsResponse{buffered(problem)}, nil
	}
	return result, nil
}

type postV1SyncCommitsResponse struct{ rawResponse }

func (r postV1SyncCommitsResponse) VisitPostV1SyncCommitsResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) GetV1SyncHead(ctx context.Context, _ api.GetV1SyncHeadRequestObject) (api.GetV1SyncHeadResponseObject, error) {
	result, problem := jsonResponse[api.GetV1SyncHead200JSONResponse](c, ctx, 200)
	if problem != nil {
		return getV1SyncHeadResponse{buffered(problem)}, nil
	}
	return result, nil
}

type getV1SyncHeadResponse struct{ rawResponse }

func (r getV1SyncHeadResponse) VisitGetV1SyncHeadResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) GetHealthz(context.Context, api.GetHealthzRequestObject) (api.GetHealthzResponseObject, error) {
	return api.GetHealthz200JSONResponse{Status: "ok"}, nil
}

func (c contract) PostV1AuthLogout(ctx context.Context, _ api.PostV1AuthLogoutRequestObject) (api.PostV1AuthLogoutResponseObject, error) {
	return postV1AuthLogoutResponse{raw(c, ctx)}, nil
}

type postV1AuthLogoutResponse struct{ rawResponse }

func (r postV1AuthLogoutResponse) VisitPostV1AuthLogoutResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) DeleteV1BackupsId(ctx context.Context, _ api.DeleteV1BackupsIdRequestObject) (api.DeleteV1BackupsIdResponseObject, error) {
	return deleteV1BackupsIdResponse{raw(c, ctx)}, nil
}

type deleteV1BackupsIdResponse struct{ rawResponse }

func (r deleteV1BackupsIdResponse) VisitDeleteV1BackupsIdResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) GetV1BackupsId(ctx context.Context, _ api.GetV1BackupsIdRequestObject) (api.GetV1BackupsIdResponseObject, error) {
	return getV1BackupsIdResponse{raw(c, ctx)}, nil
}

type getV1BackupsIdResponse struct{ rawResponse }

func (r getV1BackupsIdResponse) VisitGetV1BackupsIdResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) GetV1BlobsSha256(ctx context.Context, _ api.GetV1BlobsSha256RequestObject) (api.GetV1BlobsSha256ResponseObject, error) {
	return getV1BlobsSha256Response{raw(c, ctx)}, nil
}

type getV1BlobsSha256Response struct{ rawResponse }

func (r getV1BlobsSha256Response) VisitGetV1BlobsSha256Response(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) HeadV1BlobsSha256(ctx context.Context, _ api.HeadV1BlobsSha256RequestObject) (api.HeadV1BlobsSha256ResponseObject, error) {
	return headV1BlobsSha256Response{raw(c, ctx)}, nil
}

type headV1BlobsSha256Response struct{ rawResponse }

func (r headV1BlobsSha256Response) VisitHeadV1BlobsSha256Response(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) PutV1BlobsSha256(ctx context.Context, _ api.PutV1BlobsSha256RequestObject) (api.PutV1BlobsSha256ResponseObject, error) {
	return putV1BlobsSha256Response{raw(c, ctx)}, nil
}

type putV1BlobsSha256Response struct{ rawResponse }

func (r putV1BlobsSha256Response) VisitPutV1BlobsSha256Response(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) PostV1LlmChatCompletions(ctx context.Context, _ api.PostV1LlmChatCompletionsRequestObject) (api.PostV1LlmChatCompletionsResponseObject, error) {
	return postV1LlmChatCompletionsResponse{raw(c, ctx)}, nil
}

type postV1LlmChatCompletionsResponse struct{ rawResponse }

func (r postV1LlmChatCompletionsResponse) VisitPostV1LlmChatCompletionsResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) GetV1LlmModels(ctx context.Context, _ api.GetV1LlmModelsRequestObject) (api.GetV1LlmModelsResponseObject, error) {
	return getV1LlmModelsResponse{raw(c, ctx)}, nil
}

type getV1LlmModelsResponse struct{ rawResponse }

func (r getV1LlmModelsResponse) VisitGetV1LlmModelsResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (c contract) DeleteV1Me(ctx context.Context, _ api.DeleteV1MeRequestObject) (api.DeleteV1MeResponseObject, error) {
	return deleteV1MeResponse{raw(c, ctx)}, nil
}

type deleteV1MeResponse struct{ rawResponse }

func (r deleteV1MeResponse) VisitDeleteV1MeResponse(w http.ResponseWriter) error { return r.write(w) }
