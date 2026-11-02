# Security

BlitzKVM controls computers: a flaw in it can hand someone a keyboard and a screen. Please report security issues privately.

## Reporting

Use GitHub's private vulnerability reporting: **Security › Report a vulnerability** on [wottpal/blitzkvm](https://github.com/wottpal/blitzkvm/security/advisories/new). Include the version (BlitzKVM › About BlitzKVM), the JetKVM firmware (JetKVM's own or the BlitzKVM build, with its release), and steps to reproduce. Please don't open a public issue for it.

Issues in the BlitzKVM firmware go to [wottpal/kvm](https://github.com/wottpal/kvm/security/advisories/new); issues in JetKVM's own firmware go to [JetKVM](https://github.com/jetkvm/kvm/security).

## Scope

In scope: the macOS app, its helper (`blitzkvm-engine`), the BlitzKVM firmware changes, and remote approvals: the protocol (`approval/`), the iOS app (`ios/`), the relay (`relay/`) and what is installed on the remote computer (`remote/`). For example:

- input reaching a device whose identity was not confirmed;
- a password or session cookie sent to a host other than the pinned device, or over a changed certificate;
- Device Settings installing a firmware or Tailscale build that doesn't match its pinned SHA-256;
- the updater installing an update that isn't signed with BlitzKVM's update key, or that comes from somewhere other than the release feed;
- the helper or app executing data received from a device;
- an approval taking effect without a valid signature from a current approver's presence key (sudo, `blitzkvm-remote confirm`), or a password typed outside the approved request (another window, twice, or without daemon-checked evidence);
- the relay, the JetKVM or anyone on the network reading a password or a request's details, or adding an approver without an owner's signature.

How the app protects sessions is described in the README under [Privacy and security](README.md#privacy-and-security) and [Architecture](README.md#architecture).

Known limits of remote approvals, not vulnerabilities by themselves (reports that go past them are welcome):

- **Root on the remote computer** can fake everything the daemon reports there.
- **Installing on the remote computer** the first time sends its password through the user's own SSH login (`remote/README.md`, Threat model): a process already running as that user can read it, or swap the target key. Updates and removal go through the installed daemon on an owner's signed order instead, without the password; an order that runs anything but the files the owner signed is in scope.
- **Macs without a Secure Enclave** (virtual machines) keep the approver keys in the login keychain; Touch ID then guards them only in the app.
- **The relay** can delay or drop boxes and pushes, and sees who talks to which JetKVM and when. Any broker key may use a relay unless its `BROKERS` list names the brokers; a broker reaches only the phones that registered with it.

## Supported versions

Fixes go into the latest release; there are no maintained older branches.
