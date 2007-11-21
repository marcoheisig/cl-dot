(in-package cl-dot)

(defvar *dot-path*
  #+(or win32 mswindows) "\"C:/Program Files/ATT/Graphviz/bin/dot.exe\""
  #-(or win32 mswindows) "/usr/bin/dot"
  "Path to `dot`")

;;; Classes

(defvar *id*)

(defclass graph ()
  ((attributes :initform nil :initarg :attributes :accessor attributes-of)
   (nodes :initform nil :initarg :nodes :accessor nodes-of)
   (edges :initform nil :initarg :edges :accessor edges-of)))

(defclass node ()
  ((attributes :initform nil :initarg :attributes :accessor attributes-of)
   (id :initform (incf *id*) :initarg :id :accessor id-of))
  (:documentation "A graph node with `dot` attributes (a plist, initarg
:ATTRIBUTES) and an optional `dot` id (initarg :ID, autogenerated
by default)."))

(defclass attributed ()
  ((attributes :initform nil :initarg :attributes :accessor attributes-of)
   (object :initarg :object :accessor object-of))
  (:documentation "Wraps an object (initarg :OBJECT) with `dot` attribute
information (a plist, initarg :ATTRIBUTES)"))

(defclass edge ()
  ((attributes :initform nil :initarg :attributes :accessor attributes-of)
   (source :initform nil :initarg :source :accessor source-of)
   (target :initform nil :initarg :target :accessor target-of)))

;;; Protocol functions

(defgeneric object-node (object)
  (:documentation
   "Return a NODE instance for this object, or NIL. In the latter case
the object will not be included in the graph, but it can still have an
indirect effect via other protocol functions (e.g. OBJECT-KNOWS-OF).
This function will only be called once for each object during the
generation of a graph."))

(defgeneric object-points-to (object)
  (:documentation
   "Return a list of objects to which the NODE of this object should be
connected. The edges will be directed from this object to the others.
To assign dot attributes to the generated edges, each object can optionally
be wrapped in a instance of ATTRIBUTED.")
  (:method ((object t))
    nil))

(defgeneric object-pointed-to-by (object)
  (:documentation
   "Return a list of objects to which the NODE of this object should be
connected. The edges will be directed from the other objects to this
one. To assign dot attributes to the generated edges, each object can
optionally be wrapped in a instance of ATTRIBUTED.")
  (:method ((object t))
    nil))

(defgeneric object-knows-of (object)
  (:documentation
   "Return a list of objects that this object knows should be part of the
graph, but which it has no direct connections to.")
  (:method ((object t))
    nil))

;;; Public interface

(defgeneric generate-graph (object &optional attributes)
  (:documentation "Construct a GRAPH with ATTRIBUTES starting
from OBJECT, using the OBJECT- protocol.")
  (:method ((object t) &optional attributes)
    (multiple-value-bind (nodes edges)
        (construct-graph object)
      (make-instance 'graph
                     :attributes attributes
                     :nodes nodes
                     :edges edges))))

(defun print-graph (graph &optional (stream *standard-output*))
  "Print a dot-format representation GRAPH to STREAM."
  (generate-dot (nodes-of graph)
                (edges-of graph)
                (attributes-of graph)
                stream))

(defun dot-graph (graph outfile &key (format :ps))
  "Renders GRAPH to OUTFILE by running the program in \*DOT-PATH*.
The default FORMAT is Postscript."
  (when (null format) (setf format :ps))
  #+sbcl
  (let ((dot-string (with-output-to-string (stream)
                      (print-graph graph stream))))
    (sb-ext:run-program *dot-path*
                        (list (format nil "-T~(~a~)" format) "-o" outfile)
                        :input (make-string-input-stream dot-string)
                        :output *standard-output*))
  #+allegro
  (excl.osi:with-command-io
      ((format nil "~A -T~(~a~) -o ~A" *dot-path* format outfile))
    (:input (dot-stream)
            (print-graph graph dot-stream)))
  #+lispworks
  (with-open-stream
      (dot-stream (sys:open-pipe (format nil "~A -T~(~a~) -o ~A"
                                         *dot-path* format outfile)
                                 :direction :input))
    (print-graph graph dot-stream)
    (force-output dot-stream))
  #-(or sbcl lispworks allegro)
  (error "Don't know how to execute a program on this platform"))

;;; Internal
(defun construct-graph (object)
  (let ((handled-objects (make-hash-table))
        (nodes nil)
        (edges nil)
        (*id* 0))
    (labels ((add-edge (source target attributes)
               (let ((edge (make-instance 'edge
                                          :attributes attributes
                                          :source source
                                          :target target)))
                 (pushnew edge edges
                          :test (lambda (a b)
                                  (and (eq (source-of a)
                                           (source-of b))
                                       (eq (target-of a)
                                           (target-of b))
                                       (equal (attributes-of a)
                                              (attributes-of b)))))))
             (get-node (object)
               (if (typep object 'attributed)
                   (get-node (object-of object))
                   (gethash object handled-objects)))
             (get-attributes (object)
               (when (typep object 'attributed)
                 (attributes-of object)))
             (handle-object (object)
               (when (typep object 'attributed)
                 (return-from handle-object (handle-object (object-of object))))
               ;; If object has been already been visited, skip
               (unless (nth-value 1 (get-node object))
                 (let ((node (object-node object)))
                   (setf (gethash object handled-objects) node)
                   (map nil #'handle-object (object-knows-of object))
                   (map nil #'handle-object (object-points-to object))
                   (map nil #'handle-object (object-pointed-to-by object))
                   (when node
                     (push node nodes)
                     (dolist (to (object-points-to object))
                       (let ((target (get-node to)))
                         (when target
                           (add-edge node target (get-attributes to)))))
                     (dolist (from (object-pointed-to-by object))
                       (let ((source (get-node from)))
                         (when source
                           (add-edge source node (get-attributes from))))))))))
      (handle-object object)
      (values nodes edges))))

(defun generate-dot (nodes edges attributes
                     &optional (*standard-output* *standard-output*))
  (with-standard-io-syntax ()
    (let ((*print-right-margin* 65535))
      (flet ((print-key-value (key value attributes)
               (destructuring-bind (key value-type)
                   (or (assoc key attributes)
                       (error "Invalid attribute ~S" key))
                 (format t "~a=~a" (string-downcase key)
                         (etypecase value-type
                           ((member integer)
                            (unless (typep value 'integer)
                              (error "Invalid value for ~S: ~S is not an integer"
                                     key value))
                            value)
                           ((member boolean)
                            (if value
                                "true"
                                "false"))
                           ((member text)
                            (textify value))
                           ((member float)
                            (coerce value 'single-float))
                           (list
                            (unless (member value value-type :test 'equal)
                              (error "Invalid value for ~S: ~S is not one of ~S"
                                     key value value-type))
                            (if (symbolp value)
                                (string-downcase value)
                                value)))))))
        (format t "digraph {~%")
        (loop for (name value) on attributes by #'cddr
              do
              (print-key-value name value *graph-attributes*)
              (format t ";~%"))
        (dolist (node nodes)
          (format t "  ~a [" (textify (id-of node)))
          (loop for (name value) on (attributes-of node) by #'cddr
                for prefix = "" then ","
                do
                (write-string prefix)
                (print-key-value name value *node-attributes*))
          (format t "];~%"))
        (dolist (edge edges)
          (format t "  ~a -> ~a ["
                  (textify (id-of (source-of edge)))
                  (textify (id-of (target-of edge))))
          (loop for (name value) on (attributes-of edge) by #'cddr
                for prefix = "" then ","
                do
                (write-string prefix)
                (print-key-value name value *edge-attributes*))
          (format t "];~%"))
        (format t "}"))
      (values))))

(defun textify (object)
  (let ((string (princ-to-string object)))
    (with-output-to-string (stream)
      (write-char #\" stream)
      (loop for c across string do
            ;; Note: #\\ should not be escaped to allow \n, \l, \N, etc.
            ;; to work.
            (case c
              ((#\")
               (write-char #\\ stream)
               (write-char c stream))
              (#\Newline
               (write-char #\\ stream)
               (write-char #\n stream))
              (t
               (write-char c stream))))
      (write-char #\" stream))))
