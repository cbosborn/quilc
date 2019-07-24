;;;; cl-tweedledum.lisp

(defpackage #:cl-quil.tweedledum
  (:use #:common-lisp
        #:cffi)
  (:local-nicknames (:a :alexandria))
  (:export #:load-tweedledum #:synthesis-dbs #:synthesis-diagonal))

(in-package #:cl-quil.tweedledum)

(cffi:define-foreign-library
    (libtweedledum :search-path "/usr/local/lib/rigetti/")
  (:darwin (:or #.(merge-pathnames "libtweedledum.dylib"
                                   (or *compile-file-truename*
                                       *load-truename*))
                "libtweedledum.dylib"
                "tweedledum.dylib"))
  (:unix  (:or #.(merge-pathnames "libtweedledum.so"
                                  (or *compile-file-truename*
                                      *load-truename*))
               "libtweedledum.so"
               "tweedledum.so"))

  (t (:default "libtweedledum")))

(defvar *tweedledum-libs-loaded* nil
  "T if the tweedledum shared library has been loaded by CFFI.")

(defcfun (%synthesis-dbs "tweedledum_synthesis_dbs")
    (:string :free-from-foreign t)
  (perm (:pointer :uint32))
  (size :int))

(defun synthesis-dbs (permutation)
  (with-foreign-object (perm :uint32 (length permutation))
    (loop :for i :below (length permutation)
          :for p_i :in permutation :do
            (setf (cffi:mem-aref perm :uint32 i) p_i))
    (%synthesis-dbs perm (length permutation))))

;; TODO  ecpeterson a minute ago
;;         As the overripe plum scent might indicate, some changes will probably need to be made
(defun compile-perm-gate-with-tweedledum (instr)
  "Compile the cl-quil instruction INSTR using tweedledum's permutation gate
compilation routines. Conforms to the cl-quil compiler interface, and calls
GIVE-UP-COMPILATION if INSTR is not a permutation gate."
  (unless (slot-boundp instr 'quil::name-resolution)
    (quil::give-up-compilation))
  (let ((res (quil::gate-application-resolution instr)))
    (when (typep res 'quil::gate-definition)
      (setf res (quil::gate-definition-to-gate res)))
    (let* ((perm-gate (funcall
                       (quil::operator-description-gate-lifter
                        (quil::application-operator instr))
                       res))
           (qubits (reverse (quil::application-arguments instr))))
      (cond
        ((and (typep perm-gate 'quil::permutation-gate)
              (> (length qubits) 2))
         (let* ((perm (coerce (quil::permutation-gate-permutation perm-gate) 'list))
                (synth (synthesis-dbs perm))
                (code (quil::parsed-program-executable-code
                       (quil::parse-quil synth)))
                (relabler (lambda (q)
                            (setf (quil::qubit-index q)
                                  (quil::qubit-index (nth (quil::qubit-index q) qubits))))))
           (map nil (a:rcurry #'quil::%relabel-qubits relabler) code)
           (coerce code 'list)))
        (t
         (quil::give-up-compilation))))))

(defcfun (%synthesis-diagonal "tweedledum_synthesis_diagonal")
    (:string :free-from-foreign t)
  (angles (:pointer :double))
  (size :int))

(defun synthesis-diagonal (angles)
  (with-foreign-object (angles-foreign :double (length angles))
    (loop :for i :below (length angles)
          :for p_i :in angles :do
            (setf (cffi:mem-aref angles-foreign :double i) p_i))
    (%synthesis-diagonal angles-foreign (length angles))))

(defun diagonal-p (m)
  (loop :for i :below (magicl:matrix-cols m) :do
    (loop :for j :below (magicl:matrix-rows m)
          :when (and (/= i j)
                     (not (zerop (magicl:ref m i j)))) :do
                       (return-from diagonal-p nil)))
  t)

(defun compile-diagonal-gate-with-tweedledum (instr)
  ;; TODO Probably don't want to be checking for diagonality for every
  ;; instruction. Like with permutation gates, diagonality should be
  ;; available as part of the structure definition. Maybe that already
  ;; exists.
  (let ((m (quil:gate-matrix instr)))
    (unless (diagonal-p m)
      (quil::give-up-compilation))
    ;; This synthesis routine works on the unitary
    ;;
    ;;   U = diag(1, e^{-i t_1}, ..., e^{-i t_{2^n - 1}})
    ;;
    ;; and takes as input the angles t_i; hence (rest ...) and #'-
    ;; below.
    (let ((angles (mapcar (a:compose #'- #'phase) (rest (magicl:matrix-diagonal m)))))
      (coerce (quil::parsed-program-executable-code
               (quil:parse-quil
                (synthesis-diagonal angles)))
              'list))))

(defun load-tweedledum ()
  (cffi:load-foreign-library 'libtweedledum)
  ;; TODO Some error handling here
  (unless *tweedledum-libs-loaded*
    (push (constantly 'compile-perm-gate-with-tweedledum)
          cl-quil::*global-compilers*))
  (setf *tweedledum-libs-loaded* t))

(defun run-tweedledum-tests ()
  (load-tweedledum)
  (uiop:symbol-call ':cl-quil-tests
                    '#:run-cl-quil-tests))
