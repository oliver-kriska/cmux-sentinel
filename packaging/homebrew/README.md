# Homebrew formula

`cmux-sentinel.rb` is **generated** — by `scripts/make-formula.sh`, from a published `v<version>`
tag. Don't hand-edit it: the version, the url and the sha256 have to agree with each other and with
`VERSION`, and a tap quietly serving the previous release looks like a successful `brew upgrade`.

It is absent until the first release that ships it; `make formula` treats "no formula yet" as fine
and a formula that disagrees with `VERSION` as a failure.

The release sequence, and the Homebrew constraints that are silent failures when ignored, are in
[`../../docs/release.md`](../../docs/release.md).
