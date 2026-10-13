# Security

BlitzKVM controls computers: a flaw in it can hand someone a keyboard and a screen. Please report security issues privately.

## Reporting

Use GitHub's private vulnerability reporting: **Security › Report a vulnerability** on [wottpal/blitzkvm](https://github.com/wottpal/blitzkvm/security/advisories/new). Include the version (BlitzKVM › About BlitzKVM), the JetKVM firmware (JetKVM's own or the BlitzKVM build, with its release), and steps to reproduce. Please don't open a public issue for it.

Issues in the BlitzKVM firmware go to [wottpal/kvm](https://github.com/wottpal/kvm/security/advisories/new); issues in JetKVM's own firmware go to [JetKVM](https://github.com/jetkvm/kvm/security).

## Scope

In scope: the macOS app, its helper (`blitzkvm-engine`), and the BlitzKVM firmware changes. For example:

- input reaching a device whose identity was not confirmed;
- a password or session cookie sent to a host other than the pinned device, or over a changed certificate;
- JetKVM Setup installing a firmware or Tailscale build that doesn't match its pinned SHA-256;
- the helper or app executing data received from a device.

How the app protects sessions is described in the README under [Privacy and security](README.md#privacy-and-security) and [Architecture](README.md#architecture).

## Supported versions

Fixes go into the latest release; there are no maintained older branches.
