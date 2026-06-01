# Commit policy (upstream-prep)

This tree is currently in agent-assisted development. Commits land
without DCO trailers because the agent is not authorised to sign on
behalf of a real person under the [Linux Developer Certificate of
Origin](https://elinux.org/Developer_Certificate_Of_Origin).
Before any patch series is posted to `netdev`, the human author has to
take ownership of every commit and add the appropriate trailers.

## What kernel community requires

Every patch posted to `linux-kernel` / `netdev` / `rust-for-linux`
needs the following trailers on its own commit:

```
Signed-off-by: Your Name <your.email@example.org>
```

Optional but expected during review:

```
Reviewed-by: Reviewer Name <reviewer.email@example.org>
Tested-by: Tester Name <tester.email@example.org>
```

`Signed-off-by` is the Developer Certificate of Origin: by adding it
the author asserts the right to contribute the patch under the
GPL-2.0 license. Patches without DCO are silently dropped by
`patchwork` and most maintainers.

## What this tree currently does

Commits are authored by `firestrand <firestrand@gmail.com>`. No
`Signed-off-by` line is added because the agent generating the
commit messages cannot legally attest the DCO on behalf of the human
author. The human author has to add them.

## Pre-submission ritual

Before opening a PR or sending a patch series upstream:

1. Set the local commit-message template:

   ```
   git config --local commit.template .gitmessage
   ```

2. Decide the maintainer identity that will own the commits and
   set it on the local repo:

   ```
   git config --local user.name 'Your Name'
   git config --local user.email 'your.email@example.org'
   ```

3. Rewrite the existing history to add `Signed-off-by`. The safest
   shape for "add a trailer to every commit" is `git filter-repo`
   with a callback (avoid `git rebase --signoff` because the rebase
   may unnecessarily touch commit authors):

   ```
   git filter-repo --commit-callback '
     msg = commit.message.decode("utf-8")
     trailer = "Signed-off-by: Your Name <your.email@example.org>"
     if trailer not in msg:
         msg = msg.rstrip() + "\n\n" + trailer + "\n"
         commit.message = msg.encode("utf-8")
   '
   ```

4. Run `scripts/checkpatch.pl` from the kernel tree against every
   prepared patch. Address its output before posting.

5. Use `git format-patch -<count> --cover-letter --thread`
   and `git send-email` with the `MAINTAINERS`-derived to/cc list.

## Patch subject conventions

The kernel community expects subject lines in the form
`<subsystem>: <one-line summary>`. For this driver the subsystem
prefix is `net: r8125_rust:`:

```
net: r8125_rust: cache-pad debug counters to eliminate false sharing
```

The body should explain *why* (the user-visible behaviour change)
before *what* (the code change). Wrap at 75 characters.

## Assisted-by for agent-assisted commits

Linux's coding-assistant policy uses an `Assisted-by:` trailer to
identify agent help. That trailer can coexist with the human DCO
`Signed-off-by`, but it must never appear without a human sign-off:

```
net: r8125_rust: cache-pad debug counters to eliminate false sharing

The three debug counters (XMIT_CALLS, IRQ_FIRES, NAPI_POLLS) were
plain AtomicU32s sharing an L1 cache line, mutated from three
independent contexts (xmit, IRQ handler, NAPI poll). Wrap each in
CachePadded so future debug counters follow the same false-sharing
discipline as the ring indices.

Static evidence: ci/check_cache_padding.sh now covers file-scope
hot-path atomics as well as cross-context state structs.

Signed-off-by: Your Name <your.email@example.org>
Assisted-by: OpenAI:gpt-5 Codex
```

The two trailers serve different purposes -- DCO is the legal
attestation, `Assisted-by` is the audit trail. `ci/check_dco_assistedby.sh`
enforces that an assisted commit also carries a human sign-off before any
upstream submission branch is posted.
