;; Lisp code for GNU Emacs running as server process.
;; Copyright (C) 1986, 1987 Free Software Foundation, Inc.
;; Author William Sommerfeld, wesommer@athena.mit.edu.
;; Changes by peck@sun.com and by rms.

;; This file is part of GNU Emacs.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY.  No author or distributor
;; accepts responsibility to anyone for the consequences of using it
;; or for whether it serves any particular purpose or works at all,
;; unless he says so in writing.  Refer to the GNU Emacs General Public
;; License for full details.

;; Everyone is granted permission to copy, modify and redistribute
;; GNU Emacs, but only under the conditions described in the
;; GNU Emacs General Public License.   A copy of this license is
;; supposed to have been given to you along with GNU Emacs so you
;; can know your rights and responsibilities.  It should be in a
;; file named COPYING.  Among other things, the copyright notice
;; and this notice must be preserved on all copies.


;;; This Lisp code is run in Emacs when it is to operate as
;;; a server for other processes.

;;; Load this library and do M-x server-edit to enable Emacs as a server.
;;; Emacs runs the program ../etc/server as a subprocess
;;; for communication with clients.  If there are no client buffers to edit, 
;;; server-edit acts like (switch-to-buffer (other-buffer))

;;; When some other program runs "the editor" to edit a file,
;;; "the editor" can be the Emacs client program ../etc/emacsclient.
;;; This program transmits the file names to Emacs through
;;; the server subprocess, and Emacs visits them and lets you edit them.

;;; Note that any number of clients may dispatch files to emacs to be edited.

;;; When you finish editing a Server buffer, again call server-edit
;;; to mark that buffer as done for the client and switch to the next 
;;; Server buffer.  When all the buffers for a client have been edited 
;;; and exited with server-edit, the client "editor" will return
;;; to the program that invoked it.  

;;; Your editing commands and Emacs's display output go to and from
;;; the terminal in the usual way.  Thus, server operation is possible
;;; only when Emacs can talk to the terminal at the time you invoke
;;; the client.  This is possible in two cases:

;;; 1. On a window system, where Emacs runs in one window and the
;;; program that wants to use "the editor" runs in another.

;;; 2. When the program that wants to use "the editor" is running
;;; as a subprocess of Emacs.

;;; The buffer local variable "client-list" lists the clients who are waiting
;;; for this buffer to be edited.  The global variable "server-clients" lists
;;; all the waiting clients, and which files are yet to be edited for each.


(defvar server-program "server"
  "*The program to use as the edit server")

(defvar server-process nil 
  "the current server process")

(defvar server-clients nil
  "List of current server clients.
Each element is (CLIENTID FILES...) where CLIENTID is a string
that can be given to the server process to identify a client.
When a buffer is marked as \"done\", it is removed from this list.")

(defvar server-buffer-clients nil
  "List of clientids for clients requesting editing of current buffer.")

(make-variable-buffer-local 'server-buffer-clients)
(setq-default server-buffer-clients nil)
(or (assq 'server-buffer-clients minor-mode-alist)
    (setq minor-mode-alist (cons '(server-buffer-clients " Server") minor-mode-alist)))

;; If a *server* buffer exists,
;; write STRING to it for logging purposes.
(defun server-log (string)
  (if (get-buffer "*server*")
      (save-excursion
	(set-buffer "*server*")
	(goto-char (point-max))
	(insert string)
	(or (bobp) (newline)))))

(defun server-sentinel (proc msg)
  (cond ((eq (process-status proc) 'exit)
	 (server-log (message "Server subprocess exited")))
	((eq (process-status proc) 'signal)
	 (server-log (message "Server subprocess killed")))))

(defun server-start (leave-dead)
  "Start a server process, killing any existing server first.
Prefix arg means just kill any existing server."
  (interactive "P")
  ;; kill it dead!
  (if server-process
      (progn
	(set-process-sentinel server-process nil)
	(condition-case () (delete-process server-process) (error nil))))
  (condition-case () (delete-file "~/.emacs_server") (error nil))
  ;; If we already had a server, clear out associated status.
  (while server-clients
    (let ((buffer (nth 1 (car server-clients))))
      (server-buffer-done buffer)))
  (if leave-dead nil
    (setq server-process (start-process "server" nil server-program))
    (set-process-sentinel server-process 'server-sentinel)
    (set-process-filter server-process 'server-process-filter)
    (process-kill-without-query server-process)
    (server-log "Starting server")))

;Process a request from the server to edit some files.
;Format of STRING is "Client: CLIENTID PATH PATH PATH... \n"
(defun server-process-filter (proc string)
  (server-log string)
  (if (not (eq 0 (string-match "Client: " string)))
      nil
    (setq string (substring string (match-end 0)))
    (let ((client (list (substring string 0 (string-match " " string))))
	  (filenames nil))
      (setq string (substring string (match-end 0)))
      (while (string-match "[^ ]+ " string)
	(setq filenames
	      (cons (substring string (match-beginning 0) (1- (match-end 0)))
		    filenames))
	(setq string (substring string (match-end 0))))
      (server-visit-files filenames client)
      ;; CLIENT is now a list (CLIENTNUM BUFFERS...)
      (setq server-clients (cons client server-clients))
      (switch-to-buffer (nth 1 client))
      (message (substitute-command-keys
		"When done with a buffer, type \\[server-edit].")))))

(defun server-visit-files (filenames client)
  "Finds FILES and returns the list CLIENT with the buffers nconc'd."
  (let (client-record)
    (while filenames
      (save-excursion
	(let ((obuf (get-file-buffer (car filenames))))
	  ;; If there is an existing buffer that's not modified,
	  ;; revert it--don't ask for confirmation as usually would.
	  (if (and obuf (not (buffer-modified-p obuf))
		   (file-exists-p (buffer-file-name obuf)))
	      (progn
		(set-buffer obuf)
		(revert-buffer t t))
	    (set-buffer (find-file-noselect (car filenames)))))
	(setq server-buffer-clients (cons (car client) server-buffer-clients))
	(setq client-record (cons (current-buffer) client-record)))
      (setq filenames (cdr filenames)))
    (nconc client client-record)))

(defun server-buffer-done (buffer)
  "Mark BUFFER as \"done\" for its client(s).
Buries the buffer, and returns another server buffer
as a suggestion for what to select next."
  (let ((running (eq (process-status server-process) 'run))
	(next-buffer nil)
	(old-clients server-clients))
    (while old-clients
      (let ((client (car old-clients)))
	(or next-buffer 
	    (setq next-buffer (nth 1 (memq buffer client))))
	(delq buffer client)
	;; If client now has no pending buffers,
	;; tell it that it is done, and forget it entirely.
	(if (cdr client) nil
	  (if running
	      (progn
		(send-string server-process 
			     (format "Close: %s Done\n" (car client)))
		(server-log (format "Close: %s Done\n" (car client)))))
	  (setq server-clients (delq client server-clients))))
      (setq old-clients (cdr old-clients)))
    (if (buffer-name buffer)
	(save-excursion
	  (set-buffer buffer)
	  (setq server-buffer-clients nil)))
    (bury-buffer buffer)
    next-buffer))

(defun server-done ()
  "Offer to save current buffer, mark it as \"done\" for clients,
bury it, and return a suggested buffer to select next."
  (let ((buffer (current-buffer)))
    (if server-buffer-clients
	(progn
	  (if (string= (buffer-name) "draft")
	      (progn (save-buffer buffer)
		     (write-region (point-min) (point-max)
				   (concat buffer-file-name "~"))
		     (kill-buffer buffer))
	    (if (and (buffer-modified-p)
		     (y-or-n-p (concat "Save file" buffer-file-name "? ")))
		(save-buffer buffer)))
	  (server-buffer-done buffer)))))

(defun server-edit (&optional arg)
  "Switch to next server editing buffer; say \"Done\" for current buffer.
If a server buffer is current, it is marked \"done\" and optionally saved.
MH <draft> files are always saved and backed up, no questions asked.
When all of a client's buffers are marked as \"done\", the client is notified.

If there is no server process running, one is started and that's all."
  (interactive)
  (if (or arg
	  (not server-process)
	  (memq (process-status server-process) '(signal exit)))
      (server-start nil)
    (server-switch-buffer (server-done))))

(defun server-switch-buffer (next-buffer)
  "Switch to another buffer, preferably one that has a client.
Arg NEXT-BUFFER is a suggestion; if it is a live buffer, use it."
  (if next-buffer
      (if (and (bufferp next-buffer)
	       (buffer-name next-buffer))
	  (switch-to-buffer next-buffer)
	;; If NEXT-BUFFER is a dead buffer,
	;; remove the server records for it
	;; and try the next surviving server buffer.
	(server-switch-buffer
	 (server-buffer-done next-buffer)))
    (if server-clients
	(server-switch-buffer (nth 1 (car server-clients)))
      (switch-to-buffer (other-buffer)))))

(global-set-key "\C-x#" 'server-edit)
