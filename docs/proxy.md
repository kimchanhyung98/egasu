# 프록시

egasu의 HTTP 클라이언트는 지정한 프록시를 통해 원격 요청을 보낼 수 있음.

- `socks5://`, `http://`, `https://` 지원.
- 설정은 `~/.openusage/config.json` 파일에서만 변경.
- 기본값은 꺼짐.

## 설정 파일

```json
{
  "proxy": {
    "enabled": true,
    "url": "socks5://127.0.0.1:10808"
  }
}
```

인증이 필요한 프록시는 URL에 사용자 이름과 암호를 모두 입력.

```json
{
  "proxy": {
    "enabled": true,
    "url": "http://user:pass@proxy.example.com:8080"
  }
}
```

URL에 포트가 없으면 스킴의 기본 포트 사용.
SOCKS5는 1080, HTTP는 80, HTTPS는 443.

## 동작

- 설정을 처음 사용하는 시점에 파일을 한 번 읽음.
  **파일을 바꾼 뒤에는 egasu를 재시작**.
- `localhost`, `127.0.0.1`, `::1`로 보내는 요청은 프록시를 거치지 않음.
  [로컬 HTTP API](/docs/local-http-api.md)의 서버는 루프백에서 요청을 수신.
- 파일이 없거나 읽을 수 없으면 프록시 비활성화.
  `proxy.enabled`가 켜져 있지 않거나 설정을 해석할 수 없는 경우도 동일.

## 적용 범위

프로바이더 사용량 요청, 공개 상태 확인, Codex Reset Watch와 [모델 가격](/docs/pricing.md) 새로 고침에 적용.
모델 가격 소스는 마지막 성공 후 1시간이 지난 상태에서 앱이 가격을 조회하면 갱신 시작.
이 설정은 해당 요청을 보내는 앱의 HTTP 세션에 적용.
