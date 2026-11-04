/**
 * First-party cookies: reading `document.cookie`, the default cookie domain, and writes that are
 * checked by reading them back.
 */

/** Value of one cookie in a `document.cookie` string: the first non-empty one, as written. */
export function readCookie(cookieString: string | null | undefined, name: string): string | undefined {
  if (!cookieString) return undefined;
  const parts = cookieString.split(";");
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i];
    const eq = part.indexOf("=");
    if (eq === -1 || part.slice(0, eq).trim() !== name) continue;
    const value = part.slice(eq + 1).trim();
    if (value) return value;
  }
  return undefined;
}

/**
 * Two-label public suffixes under which a registrable domain has three labels (`shop.co.uk`).
 * Deliberately short: a suffix missing here makes `registrableDomain` answer the suffix itself
 * (`.co.ke`), the browser refuses that domain, and `writeCookie` falls back to a host-only cookie.
 * Hosting platforms on the Public Suffix List (`vercel.app`, `github.io`, …) take the same path.
 */
const TWO_LABEL_SUFFIXES = new Set(
  (
    "co.uk org.uk me.uk ltd.uk plc.uk net.uk ac.uk gov.uk " +
    "com.au net.au org.au edu.au gov.au asn.au id.au " +
    "co.nz net.nz org.nz govt.nz ac.nz " +
    "com.br net.br org.br gov.br " +
    "co.jp ne.jp or.jp ac.jp go.jp " +
    "co.kr or.kr co.in net.in org.in firm.in gen.in ind.in " +
    "co.za org.za web.za co.il org.il co.id or.id web.id co.th in.th " +
    "com.mx org.mx gob.mx net.mx com.ar com.co com.pe com.ve com.uy com.ec " +
    "com.cn net.cn org.cn gov.cn com.hk com.tw com.sg com.my com.ph com.vn " +
    "com.pk com.bd com.ng com.eg com.sa com.tr com.ua com.pl com.es"
  ).split(" "),
);

/**
 * The default cookie domain for a host: its registrable domain with a leading dot
 * (`a.b.example.com` → `.example.com`, `www.shop.co.uk` → `.shop.co.uk`). `undefined` — a host-only
 * cookie — for `localhost`, `*.localhost`, IP addresses, single-label hosts and bare public suffixes.
 */
export function registrableDomain(hostname: string): string | undefined {
  const host = hostname.toLowerCase().replace(/\.+$/, "");
  if (
    host.indexOf(".") === -1 ||
    /\.localhost$/.test(host) ||
    /^[\d.]+$/.test(host) || // IPv4
    host.indexOf(":") !== -1 || // IPv6, with or without brackets
    host.charAt(0) === "["
  ) {
    return undefined;
  }
  const labels = host.split(".");
  const size = TWO_LABEL_SUFFIXES.has(labels.slice(-2).join(".")) ? 3 : 2;
  return labels.length < size ? undefined : "." + labels.slice(-size).join(".");
}

/** The `document.cookie` assignment for one cookie: `Path=/`, `SameSite=Lax`, `Secure` on https. */
export function cookieLine(
  name: string,
  value: string,
  maxAgeSeconds: number,
  domain: string | undefined,
  secure: boolean,
): string {
  return (
    `${name}=${value}; Max-Age=${maxAgeSeconds}; Path=/` +
    (domain ? `; Domain=${domain}` : "") +
    "; SameSite=Lax" +
    (secure ? "; Secure" : "")
  );
}

/**
 * Write a cookie on `domain`, falling back to a host-only cookie when the browser refuses the
 * domain (a public suffix, or a domain the page is not on). Returns whether the value can be read
 * back; `false` means cookies are blocked or the name belongs to an `HttpOnly` cookie.
 */
export function writeCookie(
  name: string,
  value: string,
  maxAgeSeconds: number,
  domain: string | undefined,
  secure: boolean,
): boolean {
  const domains = domain ? [domain, undefined] : [undefined];
  for (let i = 0; i < domains.length; i++) {
    document.cookie = cookieLine(name, value, maxAgeSeconds, domains[i], secure);
    if (readCookie(document.cookie, name) === value) return true;
  }
  return false;
}
