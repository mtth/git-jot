# `git-jot(1)`

Bash script to emulate branch notes, useful for [branching workflows][1]. These
branch-local notes (_jottings_):

* persist across commits, merges, and rebases;
* can be shared and stored on remotes.


## Installation

Copy `git-jot.sh` as `git-jot` somewhere in your `$PATH`, then make it
executable. You can also install it from the [AUR][2].


## Usage

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


## Alternatives

* [Git branch descriptions](https://stackoverflow.com/q/2108405)
* [`git-branchnotes`](https://gitlab.com/mockturtle/git-branchnotes)
* [`git-branch-notes`](https://github.com/ejmr/git-branch-notes)


[1]: https://git-scm.com/book/en/v2/Git-Branching-Branching-Workflows
[2]: https://aur.archlinux.org/packages/git-jot-git
