# 知新 API 后端镜像。构建：在 server/ 下执行 docker build -t zhixin-api .
FROM golang:1.27 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/zhixin-api ./cmd/zhixin-api

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/zhixin-api /zhixin-api
EXPOSE 8080
USER nonroot
ENTRYPOINT ["/zhixin-api"]
