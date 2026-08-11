# httpfield

Shared **ordered** HTTP header field for multiplexed protocols:

- HPACK (HTTP/2) via `hpack.Header`
- QPACK (HTTP/3) via `qpack.Header`
- `http2.Header`, `client.Header` (aliases)

```odin
Header :: struct {
    name, value: string,
    name_owned, value_owned: bool, // free only when true
}
```

**Not** package `http`'s map-based `Headers` (H1 server request/response access).

Destroy with `httpfield.headers_destroy` (or `hpack.headers_destroy` / `qpack.headers_destroy` re-exports).
