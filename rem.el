;;; rem.el --- reactive memoization for Emacs Lisp. -*- lexical-binding: t -*-

;; Copyright (C) 2018 Alexander Baygeldin

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; Author: Alexander Baygeldin <a.baygeldin@gmail.com>
;; URL: https://github.com/baygeldin/rem.el
;; Keywords: maint, tools
;; Version: 0.0.1
;; Package-Requires: ((emacs "24.4"))

;;; Commentary:

;; The main purpose of rem.el is to simplify building text interfaces for Emacs.
;; It provides a bunch of utilities that when combined together allow to
;; structure your code in the MVC way. At the core, what it does is memoizing,
;; but without potential memory leaks. The approach is similar to React/Redux,
;; but simpler and adapted for Emacs reality.

;;; Code:

(require 'dash)
(require 's)
(require 'ht)

;; Private

(defun rem--s-center (len padding s)
  "If S is shorter than LEN, pad it with PADDING so it is centered."
  (declare (pure t) (side-effect-free t))
  (let* ((extra (max 0 (- len (length s))))
         (char (string-to-char padding))
         (left (make-string (ceiling extra 2) char))
         (right (make-string (floor extra 2) char)))
    (concat left s right)))

(defun rem--align-string (dir len padding s)
  "Align S according to DIR, truncate to LEN and pad it with PADDING if necessary."
  (cond ((eq dir 'right) (s-right len (s-pad-left len padding s)))
        ((eq dir 'left) (s-left len (s-pad-right len padding s)))
        (t (let* ((s (rem--s-center len padding s))
                  (start (floor (- (length s) len) 2)))
             (substring s start (+ start len))))))

(defun rem--align-array (dir len padding a)
  "Align A according to DIR, truncate to LEN and pad it with PADDING if necessary."
  (let ((extra (max 0 (- len (length a)))))
    (if (eq dir 'middle)
        (let* ((left (make-list (floor extra 2) padding))
               (right (make-list (ceiling extra 2) padding))
               (a (append left a right))
               (start (floor (- (length a) len) 2)))
          (-slice a start (+ start len)))
      (let ((filler (make-list extra padding)))
        (if (eq dir 'bottom)
            (-take-last len (append filler a))
          (-take len (append a filler)))))))

(defun rem--border (content size filler props)
  "Add BORDER of SIZE with PROPS to CONTENT."
  (cl-flet ((get-size (dir) (abs (or (and (integerp size) size) (plist-get size dir) 0)))
            (get-border (length) (apply 'propertize (s-repeat length filler) props))
            (n-join (list) (when list (s-join "\n" (-non-nil list)))))
    (let* ((top (get-size :top)) (bottom (get-size :bottom))
           (right (* 2 (get-size :right))) (left (* 2 (get-size :left)))
           (lines (s-lines content)) (len (length (car lines)))
           (left-border (get-border left)) (right-border (get-border right))
           (top-border (get-border (+ left len right))))
      (n-join (list (n-join (make-list top top-border))
                    (n-join (--map (concat left-border it right-border) lines))
                    (n-join (make-list bottom top-border)))))))

;; NOTE: not sure if 'equal test method is the best option here. It allows to
;; operate on the data store imperatively at the cost of performance. If it
;; turns out to be a bottleneck, it should be changed to a custom method that
;; checks equality of each parameter in the parameters list using the 'eq test
;; method (but with respect to text properties, of course!).
(define-hash-table-test 'rem--params-test
  'equal-including-properties 'sxhash)

(defun rem--params-ht (root component &rest keyword-args)
  "Get hash table with params for COMPONENT in ROOT hash table.
Additional arguments are specified as keyword/argument pairs."
  (or (ht-get root component)
      (let ((params (apply 'make-hash-table :test 'rem--params-test keyword-args)))
        (ht-set! root component params)
        params)))

(defun rem--copy-memo (prev-hash next-hash name params)
  "Copy memoized data from PREV-HASH to NEXT-HASH.
It copies results of rendering component NAME with PARAMS along with its dependencies."
  (let* ((prev-component (ht-get prev-hash name))
         (next-component (rem--params-ht next-hash name
                                         :size (ht-size prev-component)))
         (memoized (ht-get prev-component params)))
    (ht-set! next-component params memoized)
    (dolist (dependency (cdr memoized))
      (rem--copy-memo prev-hash next-hash (car dependency) (cdr dependency)))))

;; Core

;;;###autoload
(defmacro rem-defview (name params &optional docstring &rest forms)
  "Define NAME as a new view with an optional DOCSTRING.
PARAMS are used to render FORMS."
  (declare (indent defun)
           (doc-string 2)
           (debug (&define name lambda-list [&optional stringp] def-body)))
  `(let ((rem--prev-hash (ht-create))
         (rem--next-hash (ht-create))
         (rem--deps-stack '(nil)))
     (defun ,name ,params
       ,(if (stringp docstring) docstring)
       (prog1 (progn ,docstring ,@forms)
         (setq rem--prev-hash rem--next-hash rem--deps-stack '(nil)
               rem--next-hash (make-hash-table :size (ht-size rem--prev-hash)))))))

;;;###autoload
(defmacro rem-defcomponent (name params &optional docstring &rest forms)
  "Define NAME as a new component with an optional DOCSTRING.
PARAMS are used to render FORMS."
  (declare (indent defun)
           (doc-string 2)
           (debug (&define symbolp lambda-list [&optional stringp] def-body)))
  (let* ((handler (intern (format "%s--handler" name)))
         (context '(rem--prev-hash rem--next-hash rem--deps-stack))
         (parts (-split-on '&rest params))
         (positional (--remove (eq it '&optional) (car parts)))
         (rest (car (cadr parts)))
         (refs (cons rest positional)))
    `(progn
       (defun ,handler ,(append context params)
         (let ((args (list ,@refs)))
           (push (cons ',name args) (car rem--deps-stack))
           (-if-let* ((component (ht-get rem--prev-hash ',name))
                      (memoized (ht-get component args)))
               (prog1 (car memoized)
                 (rem--copy-memo rem--prev-hash rem--next-hash ',name args))
             (push nil rem--deps-stack)
             (let ((result (progn ,docstring ,@forms)))
               (ht-set! (rem--params-ht rem--next-hash ',name) args
                        (cons result (pop rem--deps-stack)))
               result))))
       (defmacro ,name ,params
         ,(if (stringp docstring) docstring)
         (declare (debug (body)))
         (let ((handler ',handler)
               (context ',context)
               (args (list ,@positional))
               (rest ,rest))
           `(,handler ,@context ,@args ,@rest))))))

;; Components

(rem-defcomponent rem-block (content &rest keyword-args)
  "A rectangular text block with CONTENT.

Arguments are specified as keyword/argument pairs:

:halign HALIGN -- defines horizontal alignment (either 'left, 'right or 'middle).
:valign VALID -- defines vertical alignment (eigher 'top, 'bottom or 'middle)
:filler FILLER -- a character that is used to fill space (white-space by default).
:props PROPS -- overrides text properties for content (nil by default).
:border BORDER -- either an integer or a plist with integers (e.g. '(:top 5 :left 10)).
:border-filler BORDER-FILLER -- a character that is used to fill border (white-space by default).
:border-props BORDER-PROPS -- border text properties (nil by default).
:height HEIGHT -- block's height (derived automatically by default).
:width WIDTH -- block's width (derived automatically by default).
:max-height MAX-HEIGHT -- block's max height (not limited by default).
:max-width MAX-WIDTH -- block's max width (not limited by default).
:min-height MIN-HEIGHT -- block's min height (not limited by default).
:min-width MIN-WIDTH  -- block's min width (not limited by default).
:wrap-words WRAP-WORDS -- whether to wrap long sentences (t by default)."
  (cl-flet ((key (keyword) (plist-get keyword-args keyword)))
    (let* ((content (-if-let* ((wrap-words (or (key :wrap-words)
                                               (not (member :wrap-words keyword-args))))
                               (width-limit (or (key :width) (key :max-width))))
                        (s-word-wrap width-limit content)
                      content))
           (lines (s-lines content))
           (halign (or (key :halign) 'left))
           (valign (or (key :valign) 'top))
           (filler (or (key :filler) " "))
           (content-height (length lines))
           (content-width (-max (-map 'length lines)))
           (max-height (or (key :max-height) content-height))
           (min-height (or (key :min-height) content-height))
           (max-width (or (key :max-width) content-width))
           (min-width (or (key :min-width) content-width))
           (height (or (key :height) (max min-height (min max-height content-height))))
           (width (or (key :width) (max min-width (min max-width content-width)))))
      (rem--border
       (apply 'propertize
              (s-join "\n" (--map (rem--align-string halign width filler it)
                                  (rem--align-array valign height nil lines)))
              (key :props))
       (key :border) (or (key :border-filler) " ") (key :border-props)))))

(rem-defcomponent rem-join (direction align &rest blocks)
  "Join BLOCKS of text and return a new block.
DIRECTION defines join direction (either 'row or 'column).
ALIGN defines blocks alignment (either 'start, 'end or 'middle).
If a block is an array, its elements are considered as blocks."
  (cl-flet ((align-cond (start end middle) (cond ((eq align 'start) start)
                                                 ((eq align 'end) end)
                                                 (t middle))))
    (-if-let* ((blocks (-map 's-lines (-non-nil (-flatten blocks)))))
        (if (eq direction 'column)
            (let ((width (-max (--map (length (car it)) blocks)))
                  (pad (align-cond 's-pad-right 's-pad-left 'rem--s-center)))
              (s-join "\n" (--map (funcall pad width " " it) (apply '-concat blocks))))
          (let* ((height (-max (-map 'length blocks)))
                 (dir (align-cond 'top 'bottom 'middle))
                 (blocks (--map (rem--align-array
                                 dir height (s-repeat (length (car it)) " ") it)
                                blocks)))
            (s-join "\n" (--map (apply 's-concat
                                       ;; NOTE: this inconsistency will be
                                       ;; fixed in the upcoming dash.el release
                                       (if (not (consp (cdr it)))
                                           (list (car it) (cdr it))
                                         it))
                                (apply '-zip blocks))))))))

;; Helpers

(defun rem-update (buffer view &optional save-point)
  "Replace BUFFER contents with the result of calling VIEW.
If BUFFER doesn't exist, create one. SAVE-POINT is a function
that is called right before updating buffer contents and returns
an integer, a (row . column) cons or a lambda that returns one of
these. In case SAVE-POINT returned a lambda, it's called right
after updating buffer contents. The result is used to set the
pointer. By default it restores previous row and column."
  (with-current-buffer (get-buffer-create buffer)
    (let ((inhibit-read-only t)
          (pos (if save-point (funcall save-point)
                 (cons (line-number-at-pos) (current-column)))))
      (erase-buffer)
      (insert (funcall view))
      (let ((pos (if (functionp pos) (funcall pos) pos)))
        (if (integerp pos) (goto-char pos)
          (goto-char (point-min))
          (forward-line (1- (car pos)))
          (ignore-errors (forward-char (cdr pos)))))
      (let ((p (point)))
        (--each (get-buffer-window-list buffer) (set-window-point it p))))))

(defun rem-bind (buffer view actions &optional save-point)
  "Advise `rem-update' for BUFFER, VIEW and optional SAVE-POINT after ACTIONS."
  (let ((handler (lambda (&rest _) (rem-update buffer view save-point))))
    (dolist (fn actions) (advice-add fn :after handler))))

(provide 'rem)

;;; rem.el ends here
