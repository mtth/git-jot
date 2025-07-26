# `git-jot(1)`

Bash script to emulate branch notes, useful for [branching workflows][1].

_Jottings_ (branch-local notes):

* persist across commits, merges, rebases;
* can be easily pushed and shared.

```sh
$ git jot # Open an editor to add notes to the current branch
$ # Do some work, add some commits, rebase, etc...
$ git jot # View and edit the existing note
$ git switch other-branch
$ git jot # Edit a different note
$ git switch original-branch
$ git jot -V # View the original branch's note
```


[1]: https://git-scm.com/book/en/v2/Git-Branching-Branching-Workflows
