// 简易失败限流:每 IP 在窗口内失败次数超限后,临时拒绝该 IP 一段时间。
// 注意:经 cloudflared 等隧道,所有公网连接在本机视角可能同源(127.0.0.1),
// 因此按透传头(CF-Connecting-IP)取真实客户端 IP;限流是纵深防御,
// 不是主要防线——主要防线是强随机 token + 边缘访问控制(Tailscale / Cloudflare Access)。
export class RateLimiter {
  constructor({ maxFailures = 5, windowMs = 60000, banMs = 60000 } = {}) {
    this.maxFailures = maxFailures;
    this.windowMs = windowMs;
    this.banMs = banMs;
    this.failures = new Map(); // ip -> { count, windowStart }
    this.bans = new Map(); // ip -> bannedUntil
  }

  isBanned(ip) {
    const until = this.bans.get(ip);
    if (until === undefined) return false;
    if (until > Date.now()) return true;
    this.bans.delete(ip);
    return false;
  }

  recordFailure(ip) {
    const now = Date.now();
    let f = this.failures.get(ip);
    if (!f || now - f.windowStart > this.windowMs) {
      f = { count: 0, windowStart: now };
    }
    f.count += 1;
    this.failures.set(ip, f);
    if (f.count >= this.maxFailures) {
      this.bans.set(ip, now + this.banMs);
      this.failures.delete(ip);
    }
  }

  recordSuccess(ip) {
    this.failures.delete(ip);
  }
}
