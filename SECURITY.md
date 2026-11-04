# Security

Please report vulnerabilities privately through GitHub: **Security → Report a vulnerability** on
this repository. Do not open a public issue.

Include the SDK and version, the platform, and the steps to reproduce. We aim to acknowledge
reports within three working days.

The SDKs only ever use public keys (`pk_…` for apps, `wk_…` for the web). Secret `sk_` keys
belong on your server and are refused by every SDK.
