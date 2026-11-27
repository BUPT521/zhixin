package nowpay

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/BUPT521/zhixin/server/internal/config"
)

// TestProbeVerifyIsIdempotentPerOutRequestNo 在真实或沙箱的即刻收商品上核对核销的
// 幂等性：同一个 out_request_no 连续核销两次，第二次是否返回与第一次相同的状态与
// 金额，余额是否只减少一次。
//
// 核销流水在发送之前会先做本地认领（ADR-0088），同一时刻只有一处发得出去；一次
// 结果未知之后的重试仍然按原请求号重发，幂等是这条重试能成立的前提。这个用例因此
// 是发版前必跑的一步，结果写进 docs/即刻收整改验收记录.md；不为幂等时按那一节的
// 处置改成本地终态，不能带病发版。
//
// 它默认跳过，需要下面四个条件同时满足才跑：
//   - ZHIXIN_NOWPAY_PROBE=1；
//   - 能打通支付宝网关的 api.env（与线上实例同一套 ZHIXIN_ALIPAY_* 变量）；
//   - ZHIXIN_NOWPAY_PROBE_BUYER 指向一个有积分余额的账号；
//   - 沙箱或测试商品，用例会真实核销两次一积分。
//
// 用例失败不一定是代码错：如果第二次返回的状态或金额与第一次不同，说明即刻收侧对
// 同一个请求号不幂等，这时重试不能只靠请求号，要按验收记录的处置改成本地终态。
func TestProbeVerifyIsIdempotentPerOutRequestNo(t *testing.T) {
	if os.Getenv("ZHIXIN_NOWPAY_PROBE") != "1" {
		t.Skip("未设置 ZHIXIN_NOWPAY_PROBE，跳过真实即刻收网关的幂等核对")
	}
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		t.Fatalf("读取配置失败，核对需要与实例同一套 api.env: %v", err)
	}
	if cfg.Alipay == nil || cfg.NowPay == nil {
		t.Fatal("核对需要 ZHIXIN_ALIPAY_* 与 ZHIXIN_NOWPAY_PRODUCT_ID 都配置好")
	}
	buyer := os.Getenv("ZHIXIN_NOWPAY_PROBE_BUYER")
	if buyer == "" {
		t.Fatal("核对需要 ZHIXIN_NOWPAY_PROBE_BUYER 指向一个有积分余额的账号")
	}
	client, err := NewClient(cfg.Alipay, cfg.NowPay.ProductID)
	if err != nil {
		t.Fatalf("构造即刻收客户端失败: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	before, err := client.Balance(ctx, buyer)
	if err != nil {
		t.Fatalf("读取核销前的余额失败: %v", err)
	}
	if before.Unit != UnitPoints {
		t.Fatalf("核对的商品必须按积分出售，实际单位 %q", before.Unit)
	}
	if before.Remaining < 2 {
		t.Fatalf("核对需要至少两个积分余额，实际 %d", before.Remaining)
	}

	request := VerifyRequest{
		OutRequestNo: newID("ncp_"),
		Buyer:        buyer,
		Amount:       1,
		Reason:       consumeReason,
	}
	first, err := client.Verify(ctx, request)
	if err != nil {
		t.Fatalf("第一次核销失败，先确认商品、凭证与账号: %v", err)
	}
	if first.Status != ConsumeSucceeded {
		t.Fatalf("第一次核销没有成功，无法核对幂等，状态 %q", first.Status)
	}
	second, err := client.Verify(ctx, request)
	if err != nil {
		t.Fatalf("第二次核销（同一个请求号）返回错误: %v", err)
	}
	after, err := client.Balance(ctx, buyer)
	if err != nil {
		t.Fatalf("读取核销后的余额失败: %v", err)
	}
	t.Logf("第一次 %q 扣 %d，第二次 %q 扣 %d，余额 %d → %d",
		first.Status, first.Consumed, second.Status, second.Consumed,
		before.Remaining, after.Remaining)

	if second.Status != first.Status || second.Consumed != first.Consumed {
		t.Fatalf("同一个请求号的第二次核销结果不同：第一次 %q/%d，第二次 %q/%d；"+
			"这一条失败说明不能只靠请求号重试，按即刻收整改验收记录的处置改成本地终态",
			first.Status, first.Consumed, second.Status, second.Consumed)
	}
	if dropped := before.Remaining - after.Remaining; dropped != first.Consumed {
		t.Fatalf("余额应只减少第一次的 %d 积分，实际减少 %d；重复核销扣了两次",
			first.Consumed, dropped)
	}
}
