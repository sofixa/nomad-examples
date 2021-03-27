job "traefik" {
  region      = "global"
  datacenters = ["dc1"]
  type        = "system"

  update {
    max_parallel = 1
    stagger      = "1m"

    # Enable automatically reverting to the last stable job on a failed
    # deployment.
    auto_revert = true
  }

  group "traefik" {

    network {
      port "http-priv" {
        static       = 80
        host_network = "private"
      }
      port "https-priv" {
        static       = 443
        host_network = "private"
      }
      port "http-pub" {
        static       = 80
        host_network = "public"
      }
      port "https-pub" {
        static       = 443
        host_network = "public"
      }
      port "promtail_healthcheck" {
        to           = 3000
        host_network = "private"
      }
      port "otel_health" {
        to           = 13133
        host_network = "private"
      }
      port "jaeger_thrift_compact" {
        to           = 6831
        host_network = "private"
      }
    }

    task "traefik" {
      driver = "docker"

      config {
        image = "traefik:2.4"
        args = [
          "--entryPoints.http.address=:80",
          "--entryPoints.http.transport.lifeCycle.requestAcceptGraceTimeout=15s",
          "--entryPoints.http.transport.lifeCycle.graceTimeOut=10s",
          "--entryPoints.https.address=:443",
          "--entryPoints.https.transport.lifeCycle.requestAcceptGraceTimeout=15s",
          "--entryPoints.https.transport.lifeCycle.graceTimeOut=10s",
          "--entryPoints.admin.address=:8080",
          "--entryPoints.admin.transport.lifeCycle.requestAcceptGraceTimeout=15s",
          "--entryPoints.admin.transport.lifeCycle.graceTimeOut=10s",
          "--accesslog=true",
          "--api=true",
          "--metrics=true",
          "--metrics.prometheus=true",
          "--metrics.prometheus.entryPoint=admin",
          "--metrics.prometheus.manualrouting=true",
          "--ping=true",
          "--ping.entryPoint=admin",
          "--providers.consulcatalog=true",
          "--providers.consulcatalog.endpoint.address=http://172.17.0.1:8500",
          "--providers.consulcatalog.prefix=traefik",
          "--providers.consulcatalog.defaultrule=Host(`{{ .Name }}.127.0.0.1.xip.io`)",
          "--providers.file.directory=local/traefik/",
        ]

        ports = ["http", "http-pub", "https-pub", "https"]
      }
      kill_timeout = "30s"

      resources {
        cpu    = 256 # Mhz
        memory = 256 # MB
      }

      service {
        name = "traefik"
        port = "https"

        tags = [
          "traefik.enable=true",
          "traefik.http.routers.api.rule=Host(`traefik.127.0.0.1.xip.io`)",
          "traefik.http.routers.api.service=api@internal",
        ]

        check {
          name     = "alive"
          type     = "http"
          port     = "admin"
          path     = "/ping"
          interval = "5s"
          timeout  = "2s"
        }
      }
    }
    task "opentelemetry-agent" {
      driver = "docker"

      config {
        image = "otel/opentelemetry-collector-contrib:0.22.0"

        args = [
          "--config=local/otel/config.yaml",
        ]

        ports = ["otel_health", "jaeger_thrift_compact"]
      }

      resources {
        cpu    = 256 # Mhz
        memory = 256 # MB
      }

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      service {
        check {
          name     = "health"
          type     = "http"
          port     = "otel_health"
          path     = "/"
          interval = "5s"
          timeout  = "2s"
        }
      }

      template {
        data = <<EOH
           receivers:
             jaeger:
               protocols:
                 thrift_compact:
           exporters:
             jaeger_thrift:
               url: test
               timeout: 2s
             logging:
               loglevel: debug
           processors:
             batch:
             queued_retry:
           extensions:
             health_check:
           service:
             extensions: [health_check]
             pipelines:
               traces:
                receivers: [jaeger]
                processors: [batch]
                #exporters: [jaeger_thrift]
          EOH

        destination = "local/otel/config.yaml"
      }
    }
    task "promtail" {
      driver = "docker"

      config {
        image = "grafana/promtail:2.2.0"

        args = [
          "-config.file",
          "local/config.yaml",
          "-print-config-stderr",
        ]

        ports = ["promtail_healthcheck"]
      }

      template {
        data = <<EOH
          server:
            http_listen_port: 3000
            grpc_listen_port: 0
          positions:
            filename: /alloc/positions.yaml
          client:
            url: http://{{ range service "loki" }}{{ .Address }}:{{ .Port }}{{ end }}/loki/api/v1/push
          scrape_configs:
          - job_name: local
            static_configs:
            - targets:
                - localhost
              labels:
                job: traefik
                __path__: "/alloc/logs/traefik.std*.0"
            pipeline_stages:
              - regex:
                  expression: '^(?P<remote_addr>[\w\.]+) - (?P<remote_user>[^ ]*) \[(?P<time_local>.*)\] "(?P<method>[^ ]*) (?P<request>[^ ]*) (?P<protocol>[^ ]*)" (?P<status>[\d]+) (?P<body_bytes_sent>[\d]+) "(?P<http_referer>[^"]*)" "(?P<http_user_agent>[^"]*)"?'
              - labels:
                  method:
                  status:
          EOH
        destination = "local/config.yaml"
      }

      resources {
        cpu    = 50
        memory = 512
      }

      lifecycle {
        hook    = "poststart"
        sidecar = true
      }

      service {
        check {
          type     = "http"
          port     = "promtail_healthcheck"
          path     = "/ready"
          interval = "10s"
          timeout  = "2s"
        }
      }
    }
  }
}

