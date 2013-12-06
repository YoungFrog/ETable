(require 'eieio)
(require 'dash)
(require 'etable-table-model)
(require 'etable-table-column)
(require 'etable-table-column-model)


;;; helper macros
(defmacro etable-this (slot &optional value)
  "Get the value of SLOT in `this' instance.

If VALUE is non-nil, set the value of SLOT instead.  To set the
SLOT to nil, specify :nil as the VALUE."
  (if value
      (if (eq value :nil)
          `(oset this ,slot nil)
        `(oset this ,slot ,value))
    `(oref this ,slot)))

(defmacro etable-mutate (slot form &rest forms)
  "Mutate the SLOT in this object using FORM.

The SLOTs value is captured with variable `this-slot'."
  (declare (indent 1))
  `(let ((this-slot (etable-this ,slot)))
     (oset this ,slot (progn
                        ,form
                        ,@forms))))

(defun etable-aref (data idx &rest indices)
  (let ((e (aref data idx)))
    (cl-loop for i in indices do (setq e (aref e i)))
    e))

(defun etable-list-to-vector (list)
  "Transform tabular (2D) data in LIST into nested vectors"
  (vconcat (--map (vconcat it nil) list) nil))

(defmacro etable-save-table-excursion (table &rest forms)
  (declare (indent 1)
           (debug (symbolp body)))
  `(if (etable-has-focus ,table)
       (let ((tpos (etable-get-selected-cell-position ,table)))
         (unwind-protect
             (progn
               ,@forms)
           (etable-goto-cell-position ,table tpos)))
     (save-excursion
       ,@forms)))

;;; etable view implementation
(defclass etable ()
  ((table-model :initarg :table-model
                :type etable-table-model
                :protection :private
                :documentation "Table model for this table.")
   (column-model :initarg :column-model
                 :type etable-table-column-model
                 :protection :private
                 :documentation "Column model for this table.")
   (overlay :initform nil
            :documentation "Overlay keeping track of bounds of this table.")))

(defun etable-create-table (tbl-model &optional clmn-model)
  (setq tbl-model
        (cond
         ((and (object-p tbl-model)
               (object-of-class-p tbl-model 'etable-table-model))
          etable-table-model)
         ((listp tbl-model)
          (etable-default-table-model
           "TableModel"
           :table-data (etable-list-to-vector tbl-model)))
         ((vectorp tbl-model)
          (etable-default-table-model
           "TableModel"
           :table-data tbl-model))))
  (setq
   clmn-model
   (or clmn-model
       (let ((width (etable-get-column-count tbl-model)))
         (etable-default-table-column-model
          "TableColumnModel"
          :column-list (vconcat (cl-loop for i from 1 to width collect
                                         (etable-table-column "TableColumn"
                                                              :model-index (1- i))) nil)))))
  (etable "Table" :table-model tbl-model :column-model clmn-model))

(defmethod etable-narrow-to-table ((this etable))
  (let ((ov (etable-this overlay)))
    (narrow-to-region (overlay-start ov) (overlay-end ov))))

(defmethod etable-get-column-positions ((this etable))
  (let* ((col-model (etable-this column-model))
         (col-list (etable-get-columns col-model))
         (col-margin (etable-get-column-margin col-model)))
    (cl-loop for col in (append col-list nil)
             for s = (etable-get-width col)
             then (+ s (etable-get-width col) col-margin)
             collect s)))

(defmethod etable-get-selected-cell-position ((this etable))
  (save-excursion
    (save-restriction
      (widen)
      (etable-narrow-to-table this)
      (let* ((line (line-number-at-pos))
             (col-positions (etable-get-column-positions this))
             (col (current-column))
             (col-and-offset (cl-loop for c in col-positions for i = 0 then (incf i) until (< col c)
                                      finally return (cons i (- c col)))))
        (list :row line
              :col (car col-and-offset)
              :offset (cdr col-and-offset))))))

(defmethod etable-goto-cell-position ((this etable) tpos)
  (save-restriction
    (widen)
    (etable-narrow-to-table this)
    (goto-char (point-min))
    (forward-line (plist-get tpos :row))
    (beginning-of-line)
    (let ((col (plist-get tpos :col)))
      (forward-char (- (nth col (etable-get-column-positions this))
                       (min (etable-get-column-width (etable-this column-model) col) (plist-get tpos :offset)))))))

(defmethod etable-has-focus ((this etable))
  (let ((pos (point))
        (start (overlay-start (etable-this overlay)))
        (end (overlay-end (etable-this overlay))))
    (and (>= pos start)
         (<= pos end))))

(defmethod etable-draw ((this etable) point)
  (goto-char point)
  (-when-let (ov (etable-this overlay))
    (delete-region (overlay-start ov) (overlay-end ov))
    (delete-overlay ov)
    (etable-this overlay :nil))
  (let ((ov (make-overlay (point) (point) nil nil t)))
    (overlay-put ov 'etable this)
    (overlay-put ov 'face 'sp-pair-overlay-face)
    (etable-this overlay ov))
  (etable-update this))

(defmethod etable-update ((this etable))
  (let* ((ov (etable-this overlay))
         (model (etable-this table-model))
         (col-model (etable-this column-model))
         (col-separator (make-string (etable-get-column-margin col-model) ? )))
    (etable-save-table-excursion this
      (delete-region (overlay-start ov) (overlay-end ov))
      (goto-char (overlay-start ov))
      (cl-loop for i from 0 to (1- (etable-get-row-count model)) do
               (cl-loop for j from 0 to (1- (etable-get-column-count col-model)) do
                        (let* ((col (etable-get-column col-model j))
                               (width (etable-get-width col))
                               (align (etable-get-align col))
                               (string (etable-draw-cell
                                        (etable-get-renderer col)
                                        this
                                        (etable-get-value-at model i (etable-get-model-index col))
                                        nil nil i j)))
                          (when (> (length string) width)
                            (setq string (concat (substring string 0 (- width 3)) "...")))
                          (let ((extra (- width (length string))))
                            (cond
                             ((eq align :left)
                              (setq string (concat string (make-string extra ? ))))
                             ((eq align :right)
                              (setq string (concat (make-string extra ? ) string)))
                             ((eq align :center)
                              (setq string (concat (make-string (/ (1+ extra) 2) ? ) string (make-string (/ extra 2) ? ))))))
                          (insert string))
                        (insert col-separator))
               (insert "\n")))))

(defmethod etable-remove ((this etable))
  (let ((ov (etable-this overlay)))
    (delete-region (overlay-start ov) (overlay-end ov))
    (delete-overlay ov)
    (etable-this overlay :nil)))

(provide 'etable)
