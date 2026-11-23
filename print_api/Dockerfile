FROM golang:1.22-alpine AS builder
WORKDIR /app

COPY go.mod ./
RUN go mod download

COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /print_api main.go

FROM alpine:3.20
WORKDIR /app

RUN apk add --no-cache \
    libreoffice-writer \
    libreoffice-calc \
    font-noto \
    ttf-liberation

COPY --from=builder /print_api /app/print_api

EXPOSE 8080
ENTRYPOINT ["/app/print_api", "-config", "/app/config/config.json"]
