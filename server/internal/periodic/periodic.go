// Package periodic 统一进程内的周期任务：启动时先跑一次，之后按固定间隔重跑，
// 上下文结束时停止。清理循环各自手写 ticker 与 select 时容易在退出条件上写错，
// 这里只留一份实现。
package periodic

import (
	"context"
	"time"
)

// Run 立刻执行一次 fn，之后每隔 every 执行一次，直到 ctx 结束。
//
// every 不大于 0 时只跑启动那一次，用于把周期任务配置成关闭。fn 自己负责
// 记录失败：这里不重试、不中断循环，下一次周期照常执行。
func Run(ctx context.Context, every time.Duration, fn func()) {
	fn()
	if every <= 0 {
		return
	}
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			fn()
		}
	}
}
