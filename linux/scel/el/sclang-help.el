;; copyright 2003 stefan kersten <steve@k-hornz.de>
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program; if not, write to the Free Software
;; Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
;; USA

(eval-when-compile
  (require 'cl)
  (require 'font-lock))

(eval-when-compile
  (let ((load-path
	 (if (and (boundp 'byte-compile-dest-file)
		  (stringp byte-compile-dest-file))
	     (cons (file-name-directory byte-compile-dest-file) load-path)
	   load-path)))
    (require 'sclang-util)
    (require 'sclang-interp)
    (require 'sclang-language)
    (require 'sclang-mode)))

(defcustom sclang-help-directory "~/SuperCollider/Help"
  "*Directory where the SuperCollider help files are kept."
  :group 'sclang-interface
  :version "21.3"
  :type 'directory
  :options '(:must-match))

(defcustom sclang-rtf-editor-program "ted"
  "*Name of an RTF editor program used to edit SuperCollider help files."
  :group 'sclang-programs
  :type 'string)

;; (defvar sclang-help-syntax-table nil
;;   "Syntax table used in SuperCollider help buffers.")

(defvar sclang-help-topic-alist nil
  "Alist mapping help topics to file names.")
(defvar sclang-help-topic-history nil
  "List of recently invoked help topics.")
;; (defvar sclang-help-topic-ring-length 32)
;; (defvar sclang-help-topic-ring (make-ring sclang-help-topic-ring-length))

(defvar sclang-help-file nil)
(defvar sclang-current-help-file nil)
(make-variable-buffer-local 'sclang-help-file)

;; (defvar sclang-help-mode-syntax-table nil)

(defun sclang-get-help-file (topic)
  (cdr (assoc topic sclang-help-topic-alist)))

(defun sclang-get-help-topic (file)
  (car (rassoc file sclang-help-topic-alist)))

(defun sclang-help-buffer-name (topic)
  (concat "*SCHelp: " topic "*"))

(defun sclang-rtf-file-p (file-name)
  (let ((case-fold-search t))
    (string-match ".*\\.rtf$" file)))

(defun sclang-sc-file-p (file-name)
  (let ((case-fold-search t))
    (string-match ".*\\.sc$" file)))

(defconst sclang-help-file-regexp "\\(\\(\\(\\.help\\)?\\.\\(rtf\\|sc\\)\\)\\|\\.rtfd/TXT\\.rtf\\)$")

(defun sclang-help-file-p (file-name)
  (string-match sclang-help-file-regexp file-name))

(defun sclang-help-topic-name (file-name)
  (if (string-match sclang-help-file-regexp file-name)
      (file-name-nondirectory (replace-match "" nil nil file-name 1))
    file-name))

;; =====================================================================
;; rtf parsing
;; =====================================================================

(defconst sclang-rtf-face-change-token "\0")

(defun sclang-fill-rtf-syntax-table (table)
  ;; character quote
  (modify-syntax-entry ?\\ "/" table)
  (modify-syntax-entry ?\" "." table)
  table)

(defvar sclang-rtf-syntax-table (sclang-fill-rtf-syntax-table (make-syntax-table))
  "Syntax table used for RTF parsing.")

(defvar sclang-rtf-font-map '((Helvetica . variable-pitch)
			      (Helvetica-Bold . variable-pitch)
			      (Monaco . nil)))

(defstruct sclang-rtf-state
  output font-table font face pos)

(defmacro with-sclang-rtf-state-output (state &rest body)
  `(with-current-buffer (sclang-rtf-state-output ,state)
     ,@body))

(defmacro sclang-rtf-state-add-font (state font-id font-name)
  `(push (cons ,font-id (intern ,font-name)) (sclang-rtf-state-font-table ,state)))

(defmacro sclang-rtf-state-apply (state)
  (let ((pos (gensym))
	(font (gensym))
	(face (gensym)))
    `(with-current-buffer (sclang-rtf-state-output ,state)
       (let ((,pos (or (sclang-rtf-state-pos ,state) (point-min)))
	     (,font (cdr (assq
			  (cdr (assoc
				(sclang-rtf-state-font ,state)
				(sclang-rtf-state-font-table ,state)))
			  sclang-rtf-font-map)))
	     (,face (sclang-rtf-state-face ,state)))
	 (if ,font
	     (add-text-properties
	      ,pos (point)
	      (list 'rtf-p t 'rtf-face (append (list ,font) ,face))))
	 (setf (sclang-rtf-state-pos ,state) (point))))))

(defmacro sclang-rtf-state-set-font (state font)
  `(progn
     (sclang-rtf-state-apply ,state)
     (setf (sclang-rtf-state-font ,state) ,font)))

(defmacro sclang-rtf-state-push-face (state face)
  (let ((list (gensym)))
    `(let ((,list (sclang-rtf-state-face state)))
       (sclang-rtf-state-apply ,state)
       (unless (memq ,face ,list)
	 (setf (sclang-rtf-state-face ,state)
	       (append ,list (list ,face)))))))

(defmacro sclang-rtf-state-pop-face (state face)
  (let ((list (gensym)))
    `(let* ((,list (sclang-rtf-state-face ,state)))
       (sclang-rtf-state-apply ,state)
       (setf (sclang-rtf-state-face ,state) (delq ,face ,list)))))

(defun sclang-parse-rtf (state)
  (while (not (eobp))
    (cond ((looking-at "{")			; container
	   (let ((beg (point)))
	     (with-syntax-table sclang-rtf-syntax-table
	       (forward-list 1))
	     (save-excursion
	       (save-restriction
		 (narrow-to-region (1+ beg) (1- (point)))
		 (goto-char (point-min))
		 (sclang-parse-rtf-container state)
		 (widen)))))
	  ((looking-at "\\\\\\([{}\\\n]\\)")	; escape
	   (princ (match-string 1))
	   (goto-char (match-end 0)))
	  ((looking-at "\\\\\\([^\\ \n]+\\) ?")
	   (let ((end (match-end 0)))
	     (sclang-parse-rtf-control state (match-string 1))
	     (goto-char end)))
	  ((looking-at "\\([^{\\\n]+\\)")	; normal text
	   (princ (match-string 1))
	   (goto-char (match-end 0)))
	  (t (forward-char 1)))))

(defun sclang-parse-rtf-container (state)
  (cond ((looking-at "\\\\rtf1")		; document
	 (goto-char (match-end 0))
	 (sclang-parse-rtf state))
	((looking-at "\\\\fonttbl")		; font table
	 (goto-char (match-end 0))
	 (while (looking-at "\\\\\\(f[0-9]+\\)[^ ]* \\([^;]*\\);[^\\]*")
	   (sclang-rtf-state-add-font state (match-string 1) (match-string 2))
	   (goto-char (match-end 0))))
	((looking-at "{\\\\NeXTGraphic \\([^\\]+\\.[a-z]+\\)") ; inline graphic
	 (let* ((file (match-string 1))
		(image (and file (create-image (expand-file-name file)))))
	   (if image
	       (with-sclang-rtf-state-output state (insert-image image))
	     (sclang-rtf-state-push-face state 'italic)
	     (princ file)
	     (sclang-rtf-state-pop-face state 'italic))))
	))

(defun sclang-parse-rtf-control (state ctrl)
  (let ((char (aref ctrl 0)))
    (cond ((string= ctrl "par")
	   (princ "\n"))
	  ((string= ctrl "tab")
	   (princ "\t"))
	  ((or (eq char ?{) (eq char ?}))
	   (princ (char-to-string char)))
	  ((string= ctrl "b")
	   (sclang-rtf-state-push-face state 'bold))
	  ((string= ctrl "b0")
	   (sclang-rtf-state-pop-face state 'bold))
	  ((string-match "^f[0-9]+$" ctrl)
	   (sclang-rtf-state-set-font state ctrl))
	  )))

(defun sclang-convert-rtf-buffer (output)
  (let ((case-fold-search nil)
	(fill-column 80)
	(standard-output output))
    (save-excursion
      (goto-char (point-min))
      (when (looking-at "{\\\\rtf1")
	(let ((state (make-sclang-rtf-state)))
	  (setf (sclang-rtf-state-output state) output)
	  (sclang-parse-rtf state)
	  (sclang-rtf-state-apply state))))))

(macrolet ((rtf-p (pos) `(plist-get (text-properties-at ,pos) 'rtf-p)))
  (defun sclang-rtf-p (pos) (rtf-p pos))
  (defun sclang-code-p (pos) (not (rtf-p pos))))

;; =====================================================================
;; help file access
;; =====================================================================

(defun sclang-index-help-topics ()
  (interactive)
  (if sclang-help-directory
      (let ((case-fold-search nil)
	    (max-specpdl-size 10000)
	    result)
	(flet ((push-file
		(name path)
		(push (cons
		       (file-name-nondirectory (replace-match "" nil nil name 1))
		       path)
		      result)))
	  (flet ((index-dir
		  (dir)
		  (dolist (file (directory-files dir t "^[^.]" t))
		    (cond ((file-directory-p file)
			   (unless (string-match "CVS$" file)
			     ;; handle XXX.rtfd/TXT.rtf
			     (if (string-match "\\(\\.rtfd\\)$" file)
				 (push-file file (concat file "/TXT.rtf"))
			       ;; recurse into sub-directory
			       (index-dir file))))
			  ((string-match "\\(\\(\\.help\\)?\\.\\(rtf\\|sc\\)\\)$" file)
			   (push-file file file))))
		  result))
	    (sclang-message "Indexing help topics ...")
	    (index-dir sclang-help-directory)
	    (setq sclang-help-topic-alist
		  (sort result (lambda (a b) (string< (car a) (car b)))))
	    (sclang-message "Indexing help topics ... Done"))))
	(setq sclang-help-topic-alist nil)
	(sclang-message "Help directory is unset")))

(defun sclang-edit-help-file ()
  (interactive)
  (if (and (boundp 'sclang-help-file) sclang-help-file)
      (let ((file sclang-help-file))
	(if (file-exists-p file)
	    (if (sclang-rtf-file-p file)
		(start-process (format "*SCLang Help Editor %s*" file) nil sclang-rtf-editor-program file)
	      (find-file file))
	  (sclang-message "Help file not found")))
    (sclang-message "Buffer has no associated help file")))

(defun sclang-help-topic-at-point ()
  "Answer the help topic at point, or nil if not found."
  (save-excursion
    (with-syntax-table sclang-help-mode-syntax-table
      (let (beg end)
	(skip-syntax-backward "w_")
	(setq beg (point))
	(skip-syntax-forward "w_")
	(setq end (point))
	(goto-char beg)
	(buffer-substring-no-properties beg end)))))

(defun sclang-find-help (topic)
  (interactive
   (list
    (let ((topic (or (and mark-active (buffer-substring-no-properties (region-beginning) (region-end)))
		     (sclang-help-topic-at-point))))
      (completing-read (format "Help topic%s: " (if (sclang-get-help-file topic)
						    (format " (default %s)" topic) ""))
		       sclang-help-topic-alist nil t nil 'sclang-help-topic-history topic))))
  (let ((file (sclang-get-help-file topic)))
    (if file
	(if (file-exists-p file)
	    (let* ((buffer-name (sclang-help-buffer-name topic))
		   (buffer (get-buffer buffer-name)))
	      (unless buffer
		(setq buffer (get-buffer-create buffer-name))
		(with-current-buffer buffer
		  (insert-file-contents file)
		  (let ((sclang-current-help-file file)
			(default-directory (file-name-directory file)))
		    (sclang-help-mode))
		  (set-buffer-modified-p nil)))
	      (switch-to-buffer buffer))
	  (sclang-message "Help file not found"))
      (sclang-message "No help for \"%s\"" topic))))

;; =====================================================================
;; help mode
;; =====================================================================

(defun sclang-fill-help-syntax-table (table)
  ;; make ?- be part of symbols for selection and sclang-symbol-at-point
  (modify-syntax-entry ?- "_" table))

(defun sclang-fill-help-mode-map (map)
  (define-key map "\C-c}" 'bury-buffer)
  (define-key map "\C-c\C-v" 'sclang-edit-help-file))

(defmacro sclang-help-mode-limit-point-to-code (&rest body)
  (let ((min (gensym))
	(max (gensym))
	(res (gensym)))
    `(if (and (sclang-code-p (point))
	      (not (or (bobp) (eobp)))
	      (sclang-code-p (1- (point)))
	      (sclang-code-p (1+ (point))))
	 (let ((,min (previous-single-property-change (point) 'rtf-p (current-buffer) (point-min)))
	       (,max (next-single-property-change (point) 'rtf-p (current-buffer) (point-max))))
	   (let ((,res (progn ,@body)))
	     (cond ((< (point) ,min) (goto-char ,min) nil)
		   ((> (point) ,max) (goto-char ,max) nil)
		   (t ,res)))))))

(defun sclang-help-mode-beginning-of-defun (&optional arg)
  (interactive "p")
  (sclang-help-mode-limit-point-to-code (sclang-beginning-of-defun arg)))

(defun sclang-help-mode-end-of-defun (&optional arg)
  (interactive "p")
  (sclang-help-mode-limit-point-to-code (sclang-end-of-defun arg)))

(defun sclang-help-mode-fontify-region (start end loudly)
  (flet ((fontify-code
	  (start end loudly)
	  (funcall 'font-lock-default-fontify-region start end loudly))
	 (fontify-non-code
	  (start end loudly)
	  (while (< start end)
	    (let ((value (plist-get (text-properties-at start) 'rtf-face))
		  (end (next-single-property-change start 'rtf-face (current-buffer) end)))
		(add-text-properties start end (list 'face (append '(variable-pitch) (list value))))
		(setq start end)))))
    (let ((modified (buffer-modified-p)) (buffer-undo-list t)
	  (inhibit-read-only t) (inhibit-point-motion-hooks t)
	  (inhibit-modification-hooks t)
	  deactivate-mark buffer-file-name buffer-file-truename
	  (pos start))
      (unwind-protect
	  (while (< pos end)
	    (let ((end (next-single-property-change pos 'rtf-p (current-buffer) end)))
	      (if (sclang-rtf-p pos)
		  (fontify-non-code pos end loudly)
		(fontify-code pos end loudly))
	      (setq pos end)))
	(when (and (not modified) (buffer-modified-p))
	  (set-buffer-modified-p nil))))))


(defun sclang-help-mode-indent-line ()
  (if (sclang-code-p (point))
      (sclang-indent-line)
    (insert "\t")))

(define-derived-mode sclang-help-mode sclang-mode "SCLangHelp"
  "Major mode for displaying SuperCollider help files.
\\{sclang-help-mode-map}"
  (let ((file (or (buffer-file-name)
		  (and (boundp 'sclang-current-help-file)
		       sclang-current-help-file))))
    (when file
      (set-visited-file-name nil)
      (setq buffer-auto-save-file-name nil)
      (save-excursion
	(when (sclang-rtf-file-p file)
	  (let ((tmp-buffer (generate-new-buffer " *RTF*")))
	    (sclang-convert-rtf-buffer tmp-buffer)
	    (erase-buffer)
	    (insert-buffer-substring tmp-buffer)
	    (set-buffer-modified-p nil)
	    (kill-buffer tmp-buffer)))))
    (set (make-local-variable 'sclang-help-file) file)
    (setq font-lock-defaults
	  (append font-lock-defaults
		  '((font-lock-fontify-region-function . sclang-help-mode-fontify-region))))
    (set (make-local-variable 'beginning-of-defun-function) 'sclang-help-mode-beginning-of-defun)
    (setq indent-line-function #'sclang-help-mode-indent-line)
    ))

;; =====================================================================
;; debugging
;; =====================================================================

;; (setf debug-on-quit t)
;; (setf debug-on-error t)

;; (defun rtf ()
;;   (interactive)
;;   (sclang-convert-rtf-buffer (get-buffer-create "*RTF*")))

;; (defun props ()
;;   (interactive)
;;   (message "props: %s" (text-properties-at (point))))

;; (defun start-help ()
;;   (interactive)
;;   (sclang-index-help-topics)
;;   (sclang-find-help "Server"))

;; =====================================================================
;; module setup
;; =====================================================================

(add-hook 'sclang-library-startup-hook 'sclang-index-help-topics)
(sclang-fill-help-syntax-table sclang-help-mode-syntax-table)
(sclang-fill-help-mode-map sclang-help-mode-map)
(add-to-list 'auto-mode-alist '("\\.rtf$" . sclang-help-mode))

(provide 'sclang-help)

;; EOF