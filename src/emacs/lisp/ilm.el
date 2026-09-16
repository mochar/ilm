;;; ilm.el --- ilm -*- lexical-binding: t -*-

;;; Commentary:

;; ilm

;;; Code:

;;;; Requires

(require 'cl-lib)
(require 'map)
(require 'consult)

;;;; Module

(defun ilm--reload-module ()
  "Hack that copies the so file to a unique name and loads that as a module.
Note that this does not unload the previous loaded objects."
  (let ((tmp (make-temp-file "ilm_el_" nil ".so")))
    (copy-file "../../../zig-out/lib/ilm-core.so" tmp t)
    (module-load tmp)))

;;;; Core

(defvar ilm--core nil
  "Pointer to the internal Core struct.")

(defun ilm-core-init (data-dir)
  (setq ilm--core (ilm--core-init data-dir)))

(defun ilm-core-ensure ()
  "Raises an error if `ilm--core' not set or invalid, otherwise return it."
  (unless ilm--core
    (error "Ilm core invalid: not initialized"))
  (unless (ilm--core-is-valid ilm--core)
    (error "Ilm core invalid: state invalid"))
  ilm--core)

;;;; Utils

(defmacro ilm-with-special-buffer (buf-name &rest body)
  "Evaluate BODY and display the result in a popup window named BUFFER-NAME.

The buffer becomes the current buffer and `standard-output` is bound to
it.  After BODY executes, the buffer is put in
`special-mode` (dismissible with 'q')."
  (declare (indent 1) (debug t))
  (let ((buf (make-symbol "buf")))
    `(let* ((,buf (get-buffer-create ,buf-name))
            ;; Bind standard-output so `princ` and `print` write here
            (standard-output ,buf))
       (with-current-buffer ,buf
         (let ((inhibit-read-only t))
           (erase-buffer)
           ,@body)
         (special-mode)
         (goto-char (point-min)))
       (pop-to-buffer ,buf))))

;;;; Graph

(defun ilm-create-graph (id width height &optional buffer-width buffer-height)
  (ilm--core-make-graph
   ilm--core
   id
   width height
   (or buffer-width 1024)
   (or buffer-height 1024)))

(defun ilm-insert-graph (data &rest properties)
  (map-let (:canvas :width :height) data
    (insert "\n"
            (apply
             #'propertize "#"
             'display `((slice 0 0 ,width ,height) ,canvas)
             'keymap ilm-graph-map
             'ilm-graph-data data
             properties))))

(defun ilm--resize-spec-to-value (value spec)
  (pcase spec
    ((pred numberp) spec)
    (`(+ ,x) (+ value x))
    (`(- ,x) (- value x))
    (_ (error "Invalid resize spec"))))

(defun ilm-resize-graph-at-point (w-spec h-spec)
  (pcase-let* ((display (get-text-property (point) 'display))
               (data (get-text-property (point) 'ilm-graph-data))
               ((map :width :height) data)
               (new-w (ilm--resize-spec-to-value width (or w-spec width)))
               (new-h (ilm--resize-spec-to-value height (or h-spec height))))
    (ilm--core-resize-graph data new-w new-h)
    (pcase-let* (((map :width :height) data))
      (setf (nth 3 (car display)) width
            (nth 4 (car display)) height))
    ;; For some reason needed, otherwise the image size doesnt update
    ;; correctly. (redisplay) doesn't work.
   (force-mode-line-update)))

(defvar-keymap ilm-graph-map
  "l" (lambda ()
        (interactive)
        (ilm-resize-graph-at-point '(+ 30) nil))
  "h" (lambda ()
        (interactive)
        (ilm-resize-graph-at-point '(- 30) nil))
  "j" (lambda ()
        (interactive)
        (ilm-resize-graph-at-point nil '(+ 30)))
  "k" (lambda ()
        (interactive)
        (ilm-resize-graph-at-point nil '(- 30))))

;;;; Concepts

;; TODO Concept cache, just store all concepts in a var

(defun ilm-add-concept (name &optional parent-ids)
  (ilm-core-ensure)
  (ilm--core-add-concept ilm--core name parent-ids))

(defun ilm-add-concept-parents (id parent-ids)
  (ilm-core-ensure)
  (dolist (parent-id (ensure-list parent-ids))
    (ilm--core-add-concept-parent ilm--core id parent-id)))

(defun ilm-remove-concept-parents (id parent-ids)
  (ilm-core-ensure)
  (dolist (parent-id (ensure-list parent-ids))
    (ilm--core-remove-concept-parent ilm--core id parent-id)))

(defun ilm--all-concepts ()
  (ilm-core-ensure)
  (ilm--core-all-concepts ilm--core))

(defun ilm-concepts-by-ids (ids)
  (ilm-core-ensure)
  (ilm--core-concepts-by-id ilm--core ids))

(defun ilm-concept-ancestors (ids &optional direct-only)
  "Return the ancestors of concept IDS.
If DIRECT-ONLY is non-nil, only return direct parents.
Otherwise return the full hierarchy with :is_direct and :depth properties."
  (ilm-core-ensure)
  (let ((ids-list (ensure-list ids)))
    (ilm--core-concept-ancestors ilm--core ids-list (if direct-only t nil))))

(defun ilm-concept-parents (ids)
  "Return only direct parents of concept IDS."
  (ilm-concept-ancestors ids t))

(defun ilm--concept-ancestors ()
  (let* ((concept (ilm--select-concept)))
    (ilm-concept-ancestors (map-elt concept :id))))

(defun ilm-insert-concept-graph (concept &optional graph-data)
  (let* ((data (or graph-data (ilm-create-graph 'ilm-concept-graph 500 300)))
         (concept-id (map-elt concept :id)))
    (ilm--core-set-concept-graph ilm--core data concept-id)
    (ilm-insert-graph data 'concept-id concept-id)))

(defvar ilm-concept-graph-buffer "*ilm concept graph*")
(defvar ilm-concept-graph-buffer-data nil)

(defun ilm--get-concept-graph-buffer ()
  (unless ilm-concept-graph-buffer-data
    (setq ilm-concept-graph-buffer-data (ilm-create-graph 'ilm-concept-graph-preview 500 300)))
  (let ((buf (get-buffer-create ilm-concept-graph-buffer)))
    (with-current-buffer buf
      (unless (get-text-property (point-min) 'ilm-graph-data)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (ilm-insert-graph ilm-concept-graph-buffer-data))
        (special-mode)))
    buf))

(defun ilm--concept-consult-state ()
  "State factory for previewing concepts in the original window."
  (let* ((orig-win (consult--original-window))
         (orig-buf (and (window-live-p orig-win) (window-buffer orig-win))))
    (lambda (action concept)
      (pcase action
        ('preview
         (when (window-live-p orig-win)
           (if concept
               (let* ((buf (ilm--get-concept-graph-buffer))
                      (win-w (window-body-width orig-win t))
                      (win-h (window-body-height orig-win t)))
                 (with-current-buffer buf
                   (when-let* ((pos (next-single-property-change (point-min) 'display)))
                     (save-excursion
                       (goto-char pos)
                       (ilm-resize-graph-at-point win-w win-h)))
                   (ilm--core-set-concept-graph
                    ilm--core ilm-concept-graph-buffer-data (map-elt concept :id)))
                 (set-window-buffer orig-win buf))
             ;; Restore original buffer when no candidate is selected
             (when (buffer-live-p orig-buf)
               (set-window-buffer orig-win orig-buf)))))
        ('exit
         ;; Restore original buffer when exiting the minibuffer
         (when (and (window-live-p orig-win) (buffer-live-p orig-buf))
           (set-window-buffer orig-win orig-buf)))))))

(defun ilm--select-concept ()
  (ilm-core-ensure)
  (let* ((concepts (ilm--core-all-concepts ilm--core))
         (options (mapcar (lambda (concept)
                            (map-let (:name :id) concept
                              (propertize
                               (concat name (propertize (format " #%s" id) 'invisible t))
                               'concept concept)))
                          concepts)))
    (consult--read
     options
     :prompt "Concepts: "
     :state (ilm--concept-consult-state)
     :annotate (lambda (option)
                 (let ((c (get-text-property 0 'concept option)))
                   (format " %s" (map-elt c :id))))
     :lookup
     (lambda (selected candidates &rest _)
       (consult--lookup-prop 'concept selected candidates)))))

;;;; Footer

(provide 'ilm)

;;; ilm.el ends here
