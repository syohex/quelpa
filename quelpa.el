;;; quelpa.el --- Emacs Lisp packages built directly from source

;; Copyright 2014, Steckerhalter
;; Copyright 2014, Vasilij Schneidermann <v.schneidermann@gmail.com>

;; Author: steckerhalter
;; URL: https://github.com/quelpa/quelpa
;; Version: 0.0.1
;; Package-Requires: ((package-build "0"))
;; Keywords: package management build source elpa

;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; Your personal local Emacs Lisp Package Archive (ELPA) with packages
;; built on-the-fly directly from source.

;; See the README.org for more info:
;; https://github.com/steckerhalter/quelpa/README.org

;;; Requirements:

;; Emacs 24.3.1

;;; Code:

(require 'package-build)
(require 'cl-lib)

;; --- customs / variables ---------------------------------------------------

(defgroup quelpa nil
  "Build and install packages from source code"
  :group 'package)

(defcustom quelpa-upgrade-p nil
  "When non-nil, `quelpa' will try to upgrade packages.
The global value can be overridden for each package by supplying
the `:upgrade' argument."
  :group 'quelpa
  :type 'boolean)

(defcustom quelpa-verbose t
  "When non-nil, `quelpa' prints log messages."
  :group 'quelpa
  :type 'boolean)

(defcustom quelpa-before-hook '(quelpa-init)
  "List of functions to be called before quelpa."
  :group 'quelpa
  :type 'hook)

(defcustom quelpa-after-hook '(quelpa-shutdown)
  "List of functions to be called after quelpa."
  :group 'quelpa
  :type 'hook)

(defcustom quelpa-dir (expand-file-name "quelpa" user-emacs-directory)
  "Where quelpa builds and stores packages."
  :group 'quelpa
  :type 'string)

(defcustom quelpa-build-dir (expand-file-name "build" quelpa-dir)
  "Where quelpa builds packages."
  :group 'quelpa
  :type 'string)

(defcustom quelpa-packages-dir (expand-file-name "packages" quelpa-dir)
  "Where quelpa buts built packages."
  :group 'quelpa
  :type 'string)

(defvar quelpa-initialized-p nil
  "Non-nil when quelpa has been initialized.")

;; --- compatibility for legacy `package.el' in Emacs 24.3  -------------------

(defun quelpa-setup-package-structs ()
  "Setup the struct `package-desc' when not available.
`package-desc-from-legacy' is provided to convert the legacy
vector desc into a valid PACKAGE-DESC."
  (unless (functionp 'package-desc-p)
    (cl-defstruct
        (package-desc
         (:constructor
          ;; convert legacy package desc into PACKAGE-DESC
          package-desc-from-legacy
          (pkg-info kind
                    &aux
                    (name (intern (aref pkg-info 0)))
                    (version (version-to-list (aref pkg-info 3)))
                    (summary (if (string= (aref pkg-info 2) "")
                                 "No description available."
                               (aref pkg-info 2)))
                    (reqs  (aref pkg-info 1))
                    (kind kind))))
      name
      version
      (summary "No description available.")
      reqs
      kind
      archive
      dir
      extras
      signed)))

;; --- package building ------------------------------------------------------

(defun quelpa-package-type (file)
  "Determine the package type of FILE.
Return `tar' for tarball packages, `single' for single file
packages, or nil, if FILE is not a package."
  (let ((ext (file-name-extension file)))
    (cond
     ((string= ext "tar") 'tar)
     ((string= ext "el") 'single)
     (:else nil))))

(defun quelpa-get-package-desc (file)
  "Extract and return the PACKAGE-DESC struct from FILE.
On error return nil."
  (let* ((kind (quelpa-package-type file))
         (desc (with-demoted-errors "Error getting PACKAGE-DESC: %s"
                 (with-temp-buffer
                   (insert-file-contents-literally file)
                   (pcase kind
                     (`single (package-buffer-info))
                     (`tar (tar-mode)
                           (if (help-function-arglist 'package-tar-file-info)
                               ;; legacy `package-tar-file-info' requires an arg
                               (package-tar-file-info file)
                             (with-no-warnings (package-tar-file-info)))))))))
    (pcase desc
      ((pred package-desc-p) desc)
      ((pred vectorp) (package-desc-from-legacy desc kind)))))

(defun quelpa-archive-file-name (archive-entry)
  "Return the path of the file in which the package for ARCHIVE-ENTRY is stored."
  (let* ((name (car archive-entry))
         (pkg-info (cdr archive-entry))
         (version (package-version-join (aref pkg-info 0)))
         (flavour (aref pkg-info 3)))
    (expand-file-name
     (format "%s-%s.%s" name version (if (eq flavour 'single) "el" "tar"))
     quelpa-packages-dir)))

(defun quelpa-checkout (rcp dir)
  "Return the version of the new package given a RCP.
Return nil if the package is already installed and should not be upgraded."
  (let ((name (car rcp))
        (config (cdr rcp)))
    (unless (or (and (package-installed-p name) (not quelpa-upgrade-p))
                (and (not config)
                     (quelpa-message t "no recipe found for package `%s'" name)))
      (let ((version (package-build-checkout name config dir)))
        (unless (or (let ((pkg-desc (cdr (assq name package-alist))))
                      (and pkg-desc
                           (version-list-<=
                            (version-to-list version)
                            (if (functionp 'package-desc-vers)
                                (package-desc-vers pkg-desc) ; old implementation
                              (package-desc-version (car pkg-desc))))))
                    ;; Also check built-in packages.
                    (package-built-in-p name (version-to-list version)))
          version)))))

(defun quelpa-build-package (rcp)
  "Build a package from the given recipe RCP.
Uses the `package-build' library to get the source code and build
an elpa compatible package in `quelpa-build-dir' storing it in
`quelpa-packages-dir'. Return the path to the created file or nil
if no action is necessary (like when the package is installed
already and should not be upgraded etc)."
  (let* ((name (car rcp))
         (build-dir (expand-file-name (symbol-name name) quelpa-build-dir))
         (version (quelpa-checkout rcp build-dir)))
    (when version
      (quelpa-archive-file-name
       (package-build-package (symbol-name name)
                              version
                              (pb/config-file-list (cdr rcp))
                              build-dir
                              quelpa-packages-dir)))))

;; --- helpers ---------------------------------------------------------------

(defun quelpa-message (wait format-string &rest args)
  "Log a message with FORMAT-STRING and ARGS when `quelpa-verbose' is non-nil.
If WAIT is nil don't wait after showing the message. If it is a
number, wait so many seconds. If WAIT is t wait the default time.
Return t in each case."
  (when quelpa-verbose
    (message "Quelpa: %s" (apply 'format format-string args))
    (when (or (not noninteractive) wait) ; no wait if emacs is noninteractive
      (sit-for (or (and (numberp wait) wait) 1.5) t)))
  t)

(defun quelpa-checkout-melpa ()
  "Fetch or update the melpa source code from Github."
  (pb/checkout-git 'package-build
                   '(:url "git://github.com/milkypostman/melpa.git")
                   (expand-file-name "package-build" quelpa-build-dir)))

(defun quelpa-get-melpa-recipe (name)
  "Read recipe with NAME for melpa git checkout.
Return the recipe if it exists, otherwise nil."
  (let* ((recipes-path (expand-file-name "package-build/recipes" quelpa-build-dir))
         (files (directory-files recipes-path nil "^[^\.]+"))
         (file (assoc-string name files)))
    (when file
      (with-temp-buffer
        (insert-file-contents-literally (expand-file-name file recipes-path))
        (read (buffer-string))))))

(defun quelpa-init ()
  "Setup what we need for quelpa."
  (dolist (dir (list quelpa-packages-dir quelpa-build-dir))
    (unless (file-exists-p dir) (make-directory dir t)))
  (unless quelpa-initialized-p
    (quelpa-setup-package-structs)
    (quelpa-checkout-melpa)
    (setq quelpa-initialized-p t)))

(defun quelpa-shutdown ()
  "Do things that need to be done after running quelpa."
  ;; remove the packages dir because we are done with the built pkgs
  (ignore-errors (delete-directory quelpa-packages-dir t)))

(defun quelpa-arg-rcp (arg)
  "Given recipe or package name, return an alist '(NAME . RCP).
If RCP cannot be found it will be set to nil"
  (pcase arg
    ((pred listp) arg)
    ((pred symbolp) (cons arg (cdr (quelpa-get-melpa-recipe arg))))))

(defun quelpa-parse-plist (plist)
  "Parse the optional PLIST argument of `quelpa'.
Recognized keywords are:

:upgrade

If t, `quelpa' tries to do an upgrade.
"
  (while plist
    (let ((key (car plist))
          (value (cadr plist)))
      (pcase key
        (:upgrade (setq quelpa-upgrade-p value))))
    (setq plist (cddr plist))))

(defun quelpa-package-install (arg)
  "Build and install package from ARG (a recipe or package name).
If the package has dependencies recursively call this function to
install them."
  (let ((file (quelpa-build-package (quelpa-arg-rcp arg))))
    (when file
      (let* ((pkg-desc (quelpa-get-package-desc file))
             (requires (package-desc-reqs pkg-desc)))
        (when requires
          (mapc (lambda (req)
                  (unless (equal 'emacs (car req))
                    (quelpa-package-install (car req))))
                requires))
        (package-install-file file)))))

;; --- public interface ------------------------------------------------------

;;;###autoload
(defun quelpa (arg &rest plist)
  "Build and install a package with quelpa.
ARG can be a package name (symbol) or a melpa recipe (list).
PLIST is a plist that may modify the build and/or fetch process.
If called interactively, `quelpa' will prompt for a MELPA package
to install."
  (interactive (list 'interactive))
  (run-hooks 'quelpa-before-hook)
  ;; shadow `quelpa-upgrade-p' taking the default from the global var
  (let* ((quelpa-upgrade-p quelpa-upgrade-p)
         (recipes (directory-files
                   (expand-file-name "package-build/recipes" quelpa-build-dir)
                   ;; this regexp matches all files except dotfiles
                   nil "^[^.].+$"))
         (candidate (if (eq arg 'interactive)
                        (intern (completing-read "Choose MELPA recipe: "
                                                 recipes nil t))
                      arg)))
    (quelpa-parse-plist plist)
    (quelpa-package-install candidate))
  (run-hooks 'quelpa-after-hook))

(provide 'quelpa)

;;; quelpa.el ends here
