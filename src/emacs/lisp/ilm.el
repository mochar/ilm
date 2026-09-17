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

(defun ilm--propertize-graph (data &rest properties)
  (map-let (:canvas :width :height) data
    (apply
     #'propertize "#"
     'ilm-graph-data data
     'display `((slice 0 0 ,width ,height) ,canvas)
     'keymap ilm-graph-map
     'pointer 'hand
     properties)))

(defun ilm-insert-graph (data &rest properties)
  (insert "\n"
          (apply #'ilm--propertize-graph data properties))
  ;; This will start tracking the mouse (in this buffer), which we handle unsing
  ;; <mouse-movement> event in ilm-graph-map.
  (setq-local track-mouse t))

(defun ilm--resize-spec-to-value (value spec)
  (pcase spec
    ((pred numberp) spec)
    (`(+ ,x) (+ value x))
    (`(- ,x) (- value x))
    (_ (error "Invalid resize spec"))))

(defun ilm-resize-graph-at-point (w-spec h-spec)
  "Resize the viewport dimensions of the graph at point."
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

(defun ilm-pan-graph-at-point (dx dy)
  "Pan the graph camera at point by DX and DY screen pixels."
  (interactive "nDX: \nnDY: ")
  (when-let* ((data (get-text-property (point) 'ilm-graph-data)))
    (ilm--core-pan-graph data (float dx) (float dy))
    (force-mode-line-update)))

(defun ilm-zoom-graph-at-point (factor &optional focus-x focus-y)
  "Zoom the graph camera at point by FACTOR, optionally around (FOCUS-X, FOCUS-Y)."
  (interactive "nFactor: ")
  (when-let* ((data (get-text-property (point) 'ilm-graph-data)))
    (ilm--core-zoom-graph data (float factor) (float (or focus-x -1.0)) (float (or focus-y -1.0)))
    (force-mode-line-update)))

(defun ilm-fit-graph-at-point ()
  "Fit the graph camera at point to the graph bounding box."
  (interactive)
  (when-let* ((data (get-text-property (point) 'ilm-graph-data)))
    (ilm--core-fit-graph data)
    (force-mode-line-update)))

(defvar ilm-graph-mouse-move-ms (/ 1.0 60) ; 60 FPS
  "How frequently to send mouse move events in milliseconds.")

(defun ilm-graph-mouse-move-event (event)
  (interactive "e")
  (when-let* ((posn (event-start event))
              (point (posn-point posn))
              (data (get-text-property point 'ilm-graph-data))
              (xy (posn-x-y posn)))
    (ilm--core-graph-mouse-move data (float (car xy)) (float (cdr xy)))))

(defun ilm-graph-mouse-down-event (event)
  (interactive "e")
  (when-let* ((posn (event-start event))
              (point (posn-point posn))
              (data (get-text-property point 'ilm-graph-data))
              (btn (pcase (car event)
                     ('down-mouse-1 0)
                     ('down-mouse-2 1)
                     ('down-mouse-3 2)))
              (xy (posn-x-y posn)))
    (ilm--core-graph-mouse-down
     data (float (car xy)) (float (cdr xy)) btn)))

(defun ilm-graph-mouse-up-event (event)
  (interactive "e")
  (when-let* ((posn (event-start event))
              (point (posn-point posn))
              (data (get-text-property point 'ilm-graph-data))
              (xy (posn-x-y posn)))
    (ilm--core-graph-mouse-up
     data (float (car xy)) (float (cdr xy)))))

(defun ilm-graph-mouse-event (event)
  (interactive "e")
  (ilm-graph-mouse-up-event event))

(defun ilm-graph-mouse-double-event (event)
  (interactive "e")
  (when-let* ((posn (event-start event))
              (point (posn-point posn))
              (data (get-text-property point 'ilm-graph-data))
              (xy (posn-x-y posn)))
    (ilm--core-graph-mouse-up
     data (float (car xy)) (float (cdr xy)))
    (ilm--core-fit-graph data)))
    
(defun ilm-graph-wheel-zoom (event)
  "Zoom the graph camera centered at the mouse cursor position."
  (interactive "e")
  (when-let* ((posn (event-start event))
              (point (posn-point posn))
              (data (get-text-property point 'ilm-graph-data))
              (xy (posn-x-y posn))
              (factor (cond
                       ((memq (car-safe event) '(wheel-up double-wheel-up triple-wheel-up))
                        1.05)
                       ((memq (car-safe event) '(wheel-down double-wheel-down triple-wheel-down))
                        0.95))))
    (ilm--core-zoom-graph data (float factor) (float (car xy)) (float (cdr xy)))))

(defvar-keymap ilm-graph-map
  "<mouse-movement>" #'ilm-graph-mouse-move-event
  "<down-mouse-1>" #'ilm-graph-mouse-down-event
  "<down-mouse-2>" #'ilm-graph-mouse-down-event
  "<down-mouse-3>" #'ilm-graph-mouse-down-event
  "<drag-mouse-1>" #'ilm-graph-mouse-up-event
  "<drag-mouse-2>" #'ilm-graph-mouse-up-event
  "<drag-mouse-3>" #'ilm-graph-mouse-up-event
  "<mouse-1>" #'ilm-graph-mouse-event
  "<mouse-2>" #'ilm-graph-mouse-event
  "<mouse-3>" #'ilm-graph-mouse-event
  "<double-mouse-1>" #'ilm-graph-mouse-double-event
  "<double-mouse-2>" #'ilm-graph-mouse-double-event
  "<double-mouse-3>" #'ilm-graph-mouse-double-event
  "<wheel-up>" #'ilm-graph-wheel-zoom
  "<wheel-down>" #'ilm-graph-wheel-zoom
  "+" (lambda () (interactive) (ilm-zoom-graph-at-point 1.15))
  "=" (lambda () (interactive) (ilm-zoom-graph-at-point 1.15))
  "-" (lambda () (interactive) (ilm-zoom-graph-at-point 0.85))
  "0" #'ilm-fit-graph-at-point
  "f" #'ilm-fit-graph-at-point
  "<left>" (lambda () (interactive) (ilm-pan-graph-at-point 30 0))
  "<right>" (lambda () (interactive) (ilm-pan-graph-at-point -30 0))
  "<up>" (lambda () (interactive) (ilm-pan-graph-at-point 0 30))
  "<down>" (lambda () (interactive) (ilm-pan-graph-at-point 0 -30))
  "h" (lambda () (interactive) (ilm-pan-graph-at-point 30 0))
  "l" (lambda () (interactive) (ilm-pan-graph-at-point -30 0))
  "k" (lambda () (interactive) (ilm-pan-graph-at-point 0 30))
  "j" (lambda () (interactive) (ilm-pan-graph-at-point 0 -30))
  "H" (lambda () (interactive) (ilm-resize-graph-at-point '(- 30) nil))
  "L" (lambda () (interactive) (ilm-resize-graph-at-point '(+ 30) nil))
  "K" (lambda () (interactive) (ilm-resize-graph-at-point nil '(- 30)))
  "J" (lambda () (interactive) (ilm-resize-graph-at-point nil '(+ 30))))

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
