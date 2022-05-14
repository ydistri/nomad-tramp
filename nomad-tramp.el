;;; nomad-tramp.el --- TRAMP integration for HashiCorp Nomad docker containers  -*- lexical-binding: t; -*-

;; Copyright (C) 2015 Mario Rodas <marsam@users.noreply.github.com>
;; Copyright (C) 2022 YDISTRI S.E.

;; Author: Matus Goljer <matus.goljer@ydistri.com>
;; Original Author: Mario Rodas <marsam@users.noreply.github.com>
;; URL: https://github.com/emacs-pe/docker-tramp.el
;; Keywords: docker, nomad, convenience
;; Version: 0.0.1
;; Package-Requires: ((emacs "26") (dash "2.19.1") (cl-lib "0.5"))

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; `nomad-tramp.el' offers a TRAMP method for Docker containers
;; deployed on HashiCorp Nomad.
;;
;; > **NOTE**: `nomad-tramp.el' relies on the `nomad exec`
;; > command.  Tested with nomad version 1.2.6+ but should work with
;; > any nomad version which supports exec.
;;
;; ## Usage
;;
;; Offers the TRAMP method `nomad-exec` to access running containers
;;
;;     C-x C-f /nomad-exec:user@alloc-task:/path/to/file
;;
;;     where
;;       user           is the user that you want to use inside the container (optional)
;;       alloc          is the allocation ID
;;       task           is the task name
;;
;; ### [Multi-hop][] examples
;;
;; If you container is hosted on `vm.example.net`:
;;
;;     /ssh:vm-user@vm.example.net|nomad-exec:user@f8a4a37f-web:/path/to/file
;;
;; ## Troubleshooting
;;
;; ### Tramp hangs on Alpine container
;;
;; Busyboxes built with the `ENABLE_FEATURE_EDITING_ASK_TERMINAL' config option
;; send also escape sequences, which `tramp-wait-for-output' doesn't ignores
;; correctly.  Tramp upstream fixed in [98a5112][] and is available since
;; Tramp>=2.3.
;;
;; For older versions of Tramp you can dump [docker-tramp-compat.el][] in your
;; `load-path' somewhere and add the following to your `init.el', which
;; overwrites `tramp-wait-for-output' with the patch applied:
;;
;;     (require 'docker-tramp-compat)
;;
;; ### Tramp does not respect remote `PATH'
;;
;; This is a known issue with Tramp, but is not a bug so much as a poor default
;; setting.  Adding `tramp-own-remote-path' to `tramp-remote-path' will make
;; Tramp use the remote's `PATH' environment varialbe.
;;
;;     (add-to-list 'tramp-remote-path 'tramp-own-remote-path)
;;
;; [Multi-hop]: https://www.gnu.org/software/emacs/manual/html_node/tramp/Ad_002dhoc-multi_002dhops.html
;; [98a5112]: http://git.savannah.gnu.org/cgit/tramp.git/commit/?id=98a511248a9405848ed44de48a565b0b725af82c
;; [docker-tramp-compat.el]: https://github.com/emacs-pe/docker-tramp.el/raw/master/docker-tramp-compat.el

;;; Code:
(eval-when-compile (require 'cl-lib))

(require 'dash)
(require 'tramp)
(require 'tramp-cache)

(defgroup nomad-tramp nil
  "TRAMP integration for Docker containers."
  :prefix "nomad-tramp-"
  :group 'applications
  :link '(url-link :tag "Github" "https://github.com/ydistri/nomad-tramp.el")
  :link '(emacs-commentary-link :tag "Commentary" "nomad-tramp"))

(defcustom nomad-tramp-script-directory (locate-user-emacs-file "nomad-tramp/")
  "Directory where the helper python script is installed."
  :type 'directory
  :group 'nomad-tramp)

;;;###autoload
(defcustom nomad-tramp-nomad-options nil
  "List of extra nomad options."
  :type '(repeat string)
  :group 'nomad-tramp)

(defcustom nomad-tramp-use-names t
  "If non-nil, use task.group names instead of allocation id."
  :type 'boolean
  :group 'nomad-tramp)

(defcustom nomad-tramp-nomad-addr "http://localhost:4646"
  "Address where the Nomad API is accessible."
  :type 'string
  :group 'nomad-tramp)

;;;###autoload
(defconst nomad-tramp-completion-function-alist
  '((nomad-tramp--parse-running-jobs ""))
  "Default list of (FUNCTION FILE) pairs to be examined for nomad-exec method.")

;;;###autoload
(defconst nomad-tramp-method "nomad"
  "Method to connect HashiCorp Nomad docker containers.")

(defun nomad-tramp--call-nomad-api (api-route)
  (with-current-buffer
      (url-retrieve-synchronously
       (format "%s/v1/%s" nomad-tramp-nomad-addr api-route))
    (goto-char (point-min))
    (search-forward "\n\n")
    (delete-region (point-min) (point))
    (json-read-from-string (buffer-string))
    ))

(defun nomad-tramp--running-tasks ()
  "Collect running tasks and allocations.

Return a plist of running tasks with the following keys:

- :name
- :alloc-id
- :node-name
- :task-name
- :job-type
- :client-status"
  (let* ((allocs (nomad-tramp--call-nomad-api "allocations?namespace=*"))
         (allocs-and-tasks (-mapcat
                            (-lambda ((&alist
                                       'Name
                                       'ID
                                       'NodeName
                                       'TaskStates
                                       'JobType
                                       'ClientStatus
                                       ))
                              (mapcar
                               (-lambda ((task-name))
                                 (list
                                  :name Name
                                  :alloc-id ID
                                  :node-name NodeName
                                  :task-name (symbol-name task-name)
                                  :job-type JobType
                                  :client-status ClientStatus))
                               TaskStates))
                            allocs))
         (allocs-and-tasks
          (--filter
           (and (equal (plist-get it :client-status) "running"))
           allocs-and-tasks)))
    allocs-and-tasks))

(defun nomad-tramp--parse-running-jobs (&optional ignored)
  "Return a list of (user host) tuples.

TRAMP calls this function with a filename which is IGNORED.

The user is the name of the task because TRAMP only supports
predefined templates for user, host and port.  The host is the
allocation ID and the port is the node name.

The node name is only displayed for convenience, it is not used
by nomad-tramp."
  (mapcar
   (-lambda ((&plist :name :task-name :node-name))
     (list task-name (format "%s%%%s"
                             (replace-regexp-in-string
                              "\\[\\(.*?\\)\\]"
                              ".\\1"
                              name)
                             node-name)))
   (nomad-tramp--running-tasks)))

;;;###autoload
(defun nomad-tramp-add-method ()
  "Add docker tramp method."
  (let ((script-file (file-truename (format "%s/nomad-tramp" nomad-tramp-script-directory))))
    (unless (file-exists-p nomad-tramp-script-directory)
      (make-directory nomad-tramp-script-directory t))
    (with-temp-file script-file
      (insert "#!/usr/bin/env python3

import os
import re
import json
import argparse
from urllib.request import urlopen

parser = argparse.ArgumentParser(description='Call nomad exec.')
parser.add_argument('--address', type = str, required = True,
                    help = 'Nomad server address.')
parser.add_argument('--task', type = str, required = False,
                    help = 'Task name.')
parser.add_argument('--alloc-string', type = str, required = True,
                    help = 'Allocation name and Node name connected with %.')

args = parser.parse_args()
job = args.alloc_string.split('.')[0]
alloc_name = args.alloc_string.split('%')[0]
alloc_name = re.sub(r'(.*)\\.(\\d+)$', r'\\1[\\2]', alloc_name)

response = urlopen(f'{args.address}/v1/job/{job}/allocations')
data_json = json.loads(response.read())
alloc = next((item for item in data_json if item['Name'] == alloc_name))
alloc_id = alloc['ID']
task = args.task
if task is None or task == '':
    task = list(alloc['TaskStates'].keys())[0]

os.execvp('nomad', ['nomad', 'exec', '-task', task, alloc_id, '/bin/sh'])
"))
    (chmod script-file #o755)
    (add-to-list 'tramp-methods
                 `(,nomad-tramp-method
                   (tramp-login-program ,script-file)
                   (tramp-login-args (,nomad-tramp-nomad-options
                                      ("--address" ,nomad-tramp-nomad-addr)
                                      ("--task" "%u")
                                      ("--alloc-string")
                                      ("%h")))
                   (tramp-remote-shell "/bin/sh")
                   (tramp-remote-shell-args ("-i" "-c"))))))

;;;###autoload
(eval-after-load 'tramp
  '(progn
     (nomad-tramp-add-method)
     (tramp-set-completion-function nomad-tramp-method nomad-tramp-completion-function-alist)))

(provide 'nomad-tramp)

;; Local Variables:
;; indent-tabs-mode: nil
;; End:

;;; nomad-tramp.el ends here
