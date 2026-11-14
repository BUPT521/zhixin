// Package store 保存服务端的表结构与连接入口。
//
// 表结构只有一份：schema.sql。开发阶段不写迁移（ADR-0001），结构变化时按它重建。
package store

import _ "embed"

// Schema 是 PostgreSQL 的表结构；新建库时整份执行。
//
//go:embed schema.sql
var Schema string
