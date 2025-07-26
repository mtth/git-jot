# `git-jot(1)`

Bash script to emulate branch notes, useful for [branching workflows][1]. These
branch-local notes (_jottings_):

* phttps://mtth.github.io/git-jot/ersist across commits, merges, and rebases;
* can be shared and stored on remotes.


## Quickstart

```sh
$ git jot # Open an editor to add notes to the current branch
$ # Do some work, add some commits, rebase, etc...
$ git jot # View and edit the existing branch note
$ git switch other-branch
$ git jot # Edit a different branch note
$ git switch original-branch
$ git jot -V # View the original branch's note
$ git jot -X # Push the branch's note to its default remote
```

See the [manpage](https://mtth.github.io/git-jot/) for more information.


## Installation

Copy `git-jot.sh` as `git-jot` somewhere in your `$PATH`, then make it
executable.


[1]: https://git-scm.com/book/en/v2/Git-Branching-Branching-Workflows
