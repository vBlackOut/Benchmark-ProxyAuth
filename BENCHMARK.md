# ProxyAuth Benchmarks (404 Performance)

This benchmark compares **ProxyAuth**, a high-performance proxy written in Rust, under high-load 404 response scenarios.

---

## Test Conditions

- **Machine**: AMD Threadripper 5995WX, 512GB RAM, NVMe SSD, DDR4
- **OS**: Linux (Manjaro, kernel tuned)
- **Test tool**: [`wrk`](https://github.com/wg/wrk) and [`bombardier`](https://github.com/codesenberg/bombardier)
- **Response type**: pure `404 Not Found` (no disk I/O, no backend)
- **Protocol**: HTTPS (TLS 1.3 with keep-alive)
- **Concurrency**: 200–500 connections, 10–30s duration
- **Logging**: disabled in cases

---

## Raw Results

| Engine      | RPS (avg) | CPU Usage | Max Latency | Notes                          |
|-------------|-----------|-----------|--------------|---------------------------------|
| **ProxyAuth** (Rust) | **600,000** | ~95%      | <100ms       | Zero-copy, async, custom TLS     |

---

## Performance Gain

> On 404s, ProxyAuth outperforms Nginx by **20% to 30%** consistently.

### Breakdown:

- Nginx: 450k–550k RPS max (heavily tuned)
- ProxyAuth: 600k+ RPS stable

---

## Why ProxyAuth Is Faster

- Built in **Rust**: no GC, fully async, compiled for performance
- Minimal overhead: no config parsing, no dynamic rules
- Uses [Hyper](https://github.com/hyperium/hyper): zero-cost abstractions
- Static routing, custom TLS engine, no file I/O
- No log writing or access parsing

---

## Security Notes

Even with these speeds, **token verification, header rewriting, and TLS forwarding** remain active — ProxyAuth does **not** cut corners on security.

---

