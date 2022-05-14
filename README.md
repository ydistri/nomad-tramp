# nomad-tramp - TRAMP integration for HashiCorp Nomad Docker containers

*Author:* Matus Goljer <matus.goljer@ydistri.com><br>
*Version:* 0.0.1<br>

> This project is a fork of
> https://github.com/emacs-pe/docker-tramp.el which provides
> similar functionality for Docker containers.

`nomad-tramp.el` offers a TRAMP method for Docker containers
deployed on HashiCorp Nomad.

> **NOTE**: `nomad-tramp.el` relies on the `nomad exec` command and
> python3.  Tested with nomad version 1.2.6+ but should work with
> any nomad version which supports exec.

## Usage

Offers the TRAMP method `nomad` to access running containers

    C-x C-f /nomad:task@job.task-group.alloc-index%node-name:/path/to/file

where

| task@       | The task name (optional).  Default is the first task of the task group. |
| job         | The job name.                                                           |
| task-group  | The task group name.                                                    |
| alloc-index | Allocation index.  If count = 1, it is always 0                         |
| %node-name  | Name of the node where the allocation runs (optional)                   |

## Troubleshooting

### Tramp hangs on Alpine container

Busyboxes built with the `ENABLE_FEATURE_EDITING_ASK_TERMINAL` config option
send also escape sequences, which `tramp-wait-for-output` doesn't ignores
correctly.  Tramp upstream fixed in [98a5112][] and is available since
Tramp>=2.3.

For older versions of Tramp you can dump [docker-tramp-compat.el][] in your
`load-path` somewhere and add the following to your `init.el`, which
overwrites `tramp-wait-for-output` with the patch applied:

        (require 'docker-tramp-compat)

### Tramp does not respect remote `PATH`

This is a known issue with Tramp, but is not a bug so much as a poor default
setting.  Adding `tramp-own-remote-path` to `tramp-remote-path` will make
Tramp use the remote's `PATH` environment varialbe.

        (add-to-list 'tramp-remote-path 'tramp-own-remote-path)

[98a5112]: http://git.savannah.gnu.org/cgit/tramp.git/commit/?id=98a511248a9405848ed44de48a565b0b725af82c
[docker-tramp-compat.el]: https://github.com/emacs-pe/docker-tramp.el/raw/master/docker-tramp-compat.el


---
Converted from `nomad-tramp.el` by [*el2markdown*](https://github.com/Lindydancer/el2markdown).
