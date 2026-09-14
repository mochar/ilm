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
   (or buffer-width 1000) (or buffer-height 1000)))

(defun ilm--resize-spec-to-value (value spec)
  (pcase spec
    ((pred numberp) spec)
    (`(+ ,x) (+ value x))
    (`(- ,x) (- value x))
    (_ (error "Invalid resize spec"))))

(ilm--resize-spec-to-value 10 '(- 3))

;; TODO Need a refresh function in zig
;; (defun ilm-resize-graph (graph-data w-spec h-spec)
;;   (let* ((display (get-text-property (point) 'display))
;;          (canvas (cadr display))
;;          (data (get-text-property (point) 'ilm-graph-data))
;;          (concept-id (get-text-property (point) 'concept-id))
;;          (new-w (+ 30 (map-elt data :width))))
;;     (setf (nth 3 (car display)) new-w)
;;     (setf (map-elt data :width) new-w)
;;     (ilm--core-update-graph ilm--core data concept-id)
;;     ;; For some reason needed, otherwise the image size doesnt update
;;     ;; correctly. (redisplay) doesn't work.
;;     (force-mode-line-update)
;;     ))

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
    (ilm--core-ancestors ilm--core ids-list (if direct-only t nil))))

(defun ilm-concept-parents (ids)
  "Return only direct parents of concept IDS."
  (ilm-concept-ancestors ids t))

(defun ilm--concept-ancestors ()
  (let* ((concept (ilm--select-concept)))
    (ilm-concept-ancestors (map-elt concept :id))))

(defvar ilm-concept-graph-buffer "*ilm concept graph*")

(defvar-keymap ilm-graph-map
  "l" (lambda ()
        (interactive)
        (let* ((display (get-text-property (point) 'display))
               (canvas (cadr display))
               (data (get-text-property (point) 'ilm-graph-data))
               (concept-id (get-text-property (point) 'concept-id))
               (new-w (+ 30 (map-elt data :width))))
          (setf (nth 3 (car display)) new-w)
          (setf (map-elt data :width) new-w)
          (ilm--core-update-graph ilm--core data concept-id)
           ;; For some reason needed, otherwise the image size doesnt update
           ;; correctly. (redisplay) doesn't work.
          (force-mode-line-update)
        )))
          
(defun ilm-insert-concept-graph (concept)
  (let* ((data (ilm-create-graph 'ilm-concept-graph 500 300)))
    (map-let (:graph-ptr :width :height :canvas) data
      (ilm--core-update-graph ilm--core data (map-elt concept :id))
      ;; (canvas-refresh canvas)
      (insert "\n"
              (propertize "#"
                          'display `((slice 0 0 ,width ,height) ,canvas)
                          'keymap ilm-graph-map
                          'ilm-graph-data data
                          'concept-id (map-elt concept :id))))))

(defun ilm--concept-consult-state (action concept)
  "State function for previewing concepts in consult."
  (pcase action
    ('return)
    ('exit
     (when-let* ((win (get-buffer-window ilm-concept-graph-buffer)))
       (quit-window nil win)))
    ('preview
     (if concept
         (ilm-with-special-buffer ilm-concept-graph-buffer
           (ilm-insert-concept-graph concept))
       (when-let* ((win (get-buffer-window ilm-concept-graph-buffer)))
         (quit-window nil win))))))

(defun ilm--select-concept ()
  (ilm-core-ensure)
  (let* ((concepts (ilm--core-all-concepts ilm--core))
         (options (mapcar (lambda (concept)
                            (map-let (:name :id) concept
                              (propertize
                               ;; Invisible suffix ensures candidates with
                               ;; identical names are unique strings.
                               (concat name (propertize (format " #%s" id) 'invisible t))
                               'concept concept)))
                          concepts)))
    (consult--read
     options
     :prompt "Concepts: "
     :state #'ilm--concept-consult-state
     :annotate (lambda (option)
                 (let ((c (get-text-property 0 'concept option)))
                   (format " %s" (map-elt c :id))))
     :lookup
     (lambda (selected candidates &rest _)
       (consult--lookup-prop 'concept selected candidates)))))

;;;; Footer

(provide 'ilm)

;;; ilm.el ends here
