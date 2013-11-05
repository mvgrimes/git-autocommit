# Git::AutoCommit

Tool to add/rm/commit/push/pull to a git repository whenever a change
is made. Assumes you are a regular user of git repositories and tries
to be less intrusive than other options. Uses RabbitMQ (and requires a
running instance) to keep repositories in sync.

This is still in the very early development stage, but it "works" for most
situations. To come:

- _Much more documentation_
- Resolve merge conflict
- Add everything if we get out of sync (`git add -A`)
- Reconnect to the RabbitMQ if disconnected

## Alternatives

- dvcs-autocommit
- SparkleShare
- git annex assistant

These are great tools, but didn't quite fit my needs. This is probably
most similar to dvcs-autocommit. SparkleShare seems a great tool for
the layman, and git annex/assistant looks _comprehensive_ (which maybe
good or bad depending on your perspective).
