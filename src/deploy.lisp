;;;; deploy.lisp -- Consfigurator provisioning for Navidrome on rootless Podman.
;;;;
;;;; Stack: encrypted ZFS dataset for state, rootless Podman quadlet under a
;;;; dedicated service account, HAProxy as the only reverse proxy.

(defpackage #:navidrome/deploy
  (:use #:cl #:consfigurator)
  (:local-nicknames (#:file    #:consfigurator.property.file)
                    (#:user    #:consfigurator.property.user)
                    (#:systemd #:consfigurator.property.systemd))
  (:export #:*service-user* #:*image* #:*pool* #:*fqdn* #:*music-path*
           #:*listen-port* #:*scan-schedule* #:*base-url*
           #:*haproxy-conf-dir* #:*haproxy-host-map*
           #:data-dataset #:data-mountpoint #:data-key-file #:quadlet-path
           #:quadlet-unit #:haproxy-backend #:navidrome-properties
           #:deploy-navidrome #:main))

(in-package #:navidrome/deploy)

;;; ------------------------------------------------------------------
;;; Configuration. Specials listed in *OPTIONS* can be overridden from the CLI.

(defparameter *service-user* "navidrome"
  "Unprivileged account that owns the data dataset and runs the quadlet.")

(defparameter *image* "docker.io/deluan/navidrome:0.60.3"
  "Pinned image reference. Bump deliberately; never track latest.")

(defparameter *pool* "tank"
  "ZFS pool holding the navidrome/data dataset.")

(defparameter *fqdn* "music.example.org"
  "Host name HAProxy routes to the Navidrome backend.")

(defparameter *music-path* "/tank/media/music"
  "Existing music library. Mounted read-only; this stack never writes to it.")

(defparameter *listen-port* 4533
  "Loopback port published by the container for HAProxy.")

(defparameter *scan-schedule* "@every 1h"
  "Value for ND_SCANNER_SCHEDULE.")

(defparameter *base-url* ""
  "Value for ND_BASEURL. Empty when served at the root of *fqdn*.")

(defparameter *haproxy-conf-dir* "/etc/haproxy/conf.d"
  "Directory HAProxy loads with a second -f flag.")

(defparameter *haproxy-host-map* "/etc/haproxy/hosts.map"
  "Host-to-backend map consulted by the shared HTTPS frontend.")

(defun data-dataset () (format nil "~A/navidrome/data" *pool*))
(defun data-mountpoint () "/srv/navidrome/data")
(defun data-key-file () "/etc/zfs-keys/navidrome-data.key")

(defun quadlet-path ()
  (format nil "/home/~A/.config/containers/systemd/navidrome.container"
          *service-user*))

(defun haproxy-backend-path ()
  (format nil "~A/navidrome.cfg" *haproxy-conf-dir*))

;;; ------------------------------------------------------------------
;;; Helpers

(defun lines (&rest strings)
  (format nil "~{~A~%~}" strings))

(defun chomp (string)
  (string-trim '(#\Newline #\Return #\Space) string))

(defun succeeds-p (&rest args)
  (zerop (apply #'run :for-exit args)))

(defun zfs-prop (dataset prop)
  (chomp (run :may-fail "zfs" "get" "-H" "-o" "value" prop dataset)))

(defun dataset-exists-p (name)
  (succeeds-p "zfs" "list" "-H" name))

(defun service-uid ()
  (chomp (run "id" "-u" *service-user*)))

(defun user-command (&rest cmd)
  "Wrap CMD so it runs as *SERVICE-USER* with a user systemd bus."
  (list* "runuser" "-u" *service-user* "--" "env"
         (format nil "XDG_RUNTIME_DIR=/run/user/~A" (service-uid))
         cmd))

(defun user-run (&rest cmd)
  (apply #'mrun (apply #'user-command cmd)))

(defun user-succeeds-p (&rest cmd)
  (apply #'succeeds-p (apply #'user-command cmd)))

;;; ------------------------------------------------------------------
;;; Rendered artifacts

(defun quadlet-unit ()
  (lines "# Managed by navidrome-deploy. Local edits are overwritten."
         "[Unit]"
         "Description=Navidrome music server"
         "Wants=network-online.target"
         "After=network-online.target"
         ""
         "[Container]"
         "ContainerName=navidrome"
         (format nil "Image=~A" *image*)
         "UserNS=keep-id"
         (format nil "PublishPort=127.0.0.1:~D:4533" *listen-port*)
         (format nil "Volume=~A:/data" (data-mountpoint))
         (format nil "Volume=~A:/music:ro" *music-path*)
         "Environment=ND_MUSICFOLDER=/music"
         "Environment=ND_DATAFOLDER=/data"
         (format nil "Environment=\"ND_SCANNER_SCHEDULE=~A\"" *scan-schedule*)
         (format nil "Environment=ND_BASEURL=~A" *base-url*)
         "Environment=ND_LOGLEVEL=info"
         "Environment=ND_ENABLEINSIGHTSCOLLECTOR=false"
         "Secret=navidrome-admin-password,type=env,target=ND_DEVAUTOCREATEADMINPASSWORD"
         "Secret=navidrome-encryption-key,type=env,target=ND_PASSWORDENCRYPTIONKEY"
         "HealthCmd=wget -qO- http://127.0.0.1:4533/ping"
         "HealthInterval=30s"
         "HealthOnFailure=kill"
         "NoNewPrivileges=true"
         "DropCapability=ALL"
         "ReadOnly=true"
         ""
         "[Service]"
         "Restart=on-failure"
         "TimeoutStartSec=300"
         ""
         "[Install]"
         "WantedBy=default.target"))

(defun haproxy-backend ()
  (lines "# Managed by navidrome-deploy. Local edits are overwritten."
         "backend be_navidrome"
         "    mode http"
         "    option httpchk GET /ping"
         "    http-check expect status 200"
         "    timeout server 1h"
         (format nil "    server navidrome 127.0.0.1:~D check" *listen-port*)))

(defun host-map-line ()
  (format nil "~A be_navidrome" *fqdn*))

;;; ------------------------------------------------------------------
;;; Properties

(defprop podman-available :posix ()
  (:desc "podman is installed")
  (:check (succeeds-p "sh" "-c" "command -v podman"))
  (:apply (failed-change "podman not found; install it before deploying.")))

(defprop zfs-key-file :posix (path)
  (:desc (format nil "raw ZFS key present at ~A" path))
  (:check (remote-exists-p path))
  (:apply
   (mrun "install" "-d" "-m" "0700" (directory-namestring path))
   (mrun "sh" "-c" (format nil "umask 077 && head -c 32 /dev/urandom > ~A"
                            (sh-escape path)))))

(defprop zfs-encrypted-dataset :posix (name mountpoint keyfile)
  (:desc (format nil "~A encrypted and mounted at ~A" name mountpoint))
  (:check
   (declare (ignore mountpoint keyfile))
   (and (dataset-exists-p name)
        (string= "yes" (zfs-prop name "mounted"))))
  (:apply
   (cond ((not (dataset-exists-p name))
          (mrun "zfs" "create" "-p"
                "-o" "encryption=aes-256-gcm"
                "-o" "keyformat=raw"
                "-o" (format nil "keylocation=file://~A" keyfile)
                "-o" (format nil "mountpoint=~A" mountpoint)
                name))
         (t
          (unless (string= "available" (zfs-prop name "keystatus"))
            (mrun "zfs" "load-key" name))
          (mrun "zfs" "mount" name)))))

(defprop path-owned-by :posix (path owner mode)
  (:desc (format nil "~A owned by ~A, mode ~A" path owner mode))
  (:check (string= (format nil "~A ~A" owner mode)
                   (chomp (run :may-fail "stat" "-c" "%U %a" path))))
  (:apply
   (mrun "chown" (format nil "~A:~A" owner owner) path)
   (mrun "chmod" mode path)))

(defprop music-readable :posix (path)
  (:desc (format nil "~A readable by ~A" path *service-user*))
  (:check (user-succeeds-p "test" "-r" path "-a" "-x" path))
  (:apply
   (failed-change
    (format nil "~A is not readable by ~A. Grant read+execute (group or ACL) and redeploy."
            path *service-user*))))

(defprop podman-secret :posix (name)
  (:desc (format nil "podman secret ~A exists for ~A" name *service-user*))
  (:check (user-succeeds-p "podman" "secret" "exists" name))
  (:apply
   (let ((value (mrun "sh" "-c" "head -c 32 /dev/urandom | base64 -w0")))
     (apply #'mrun :input value
            (user-command "podman" "secret" "create" name "-")))))

(defprop image-pulled :posix (image)
  (:desc (format nil "~A present in ~A's image store" image *service-user*))
  (:check (user-succeeds-p "podman" "image" "exists" image))
  (:apply (user-run "podman" "pull" image)))

(defprop user-file :posix (path content)
  (:desc (format nil "~A installed for ~A" path *service-user*))
  (:check (and (remote-exists-p path)
               (string= content (read-remote-file path))))
  (:apply
   (user-run "mkdir" "-p" (directory-namestring path))
   (write-remote-file path content :mode #o644)
   (mrun "chown" (format nil "~A:~A" *service-user* *service-user*) path)))

(defprop navidrome-restarted :posix ()
  (:desc "user systemd reloaded, navidrome restarted")
  (:apply
   (user-run "systemctl" "--user" "daemon-reload")
   (user-run "systemctl" "--user" "restart" "navidrome.service")))

(defprop navidrome-running :posix ()
  (:desc "navidrome.service active")
  (:check (user-succeeds-p "systemctl" "--user" "is-active" "--quiet"
                           "navidrome.service"))
  (:apply
   (user-run "systemctl" "--user" "daemon-reload")
   (user-run "systemctl" "--user" "start" "navidrome.service")))

(defprop haproxy-reloaded :posix ()
  (:desc "HAProxy config validated and reloaded")
  (:apply
   (mrun "haproxy" "-c" "-f" "/etc/haproxy/haproxy.cfg" "-f" *haproxy-conf-dir*)
   (mrun "systemctl" "reload" "haproxy")))

;;; ------------------------------------------------------------------
;;; Host

(defhost localhost ()
  "The machine this binary runs on. Properties are supplied at deploy time
so command-line overrides take effect.")

(defproplist navidrome-properties :posix ()
  "Ordered property list. HAProxy is wired last so the vhost is never
exposed before the admin account has been created from the secret."
  (eseqprops
   (podman-available)
   (user:has-account *service-user*)
   (systemd:lingering-enabled *service-user*)
   (zfs-key-file (data-key-file))
   (zfs-encrypted-dataset (data-dataset) (data-mountpoint) (data-key-file))
   (path-owned-by (data-mountpoint) *service-user* "750")
   (music-readable *music-path*)
   (podman-secret "navidrome-admin-password")
   (podman-secret "navidrome-encryption-key")
   (image-pulled *image*)
   (on-change (user-file (quadlet-path) (quadlet-unit))
     (navidrome-restarted))
   (navidrome-running)
   (on-change (eseqprops
               (file:has-content (haproxy-backend-path) (haproxy-backend))
               (file:contains-lines *haproxy-host-map* (host-map-line)))
     (haproxy-reloaded))))

(defun deploy-navidrome ()
  (handler-bind ((consfigurator::skipped-properties
                   (lambda (c)
                     (declare (ignore c))
                     (error "Provisioning incomplete; refusing to report success."))))
    (deploy-these :local localhost (navidrome-properties))))

;;; ------------------------------------------------------------------
;;; CLI

(defparameter *options*
  '(("--fqdn"          . *fqdn*)
    ("--music"         . *music-path*)
    ("--pool"          . *pool*)
    ("--image"         . *image*)
    ("--base-url"      . *base-url*)
    ("--scan-schedule" . *scan-schedule*)))

(defun usage ()
  (format nil "usage: navidrome-deploy [--render] [--help]~{ [~A VALUE]~}"
          (mapcar #'car *options*)))

(defun die (control &rest args)
  (format *error-output* "navidrome-deploy: ~?~%~A~%" control args (usage))
  (uiop:quit 2))

(defun apply-option (flag value)
  (let ((var (cdr (assoc flag *options* :test #'string=))))
    (unless var (die "unknown option ~A" flag))
    (unless value (die "~A needs a value" flag))
    (setf (symbol-value var) value)))

(defun render ()
  (format t "## ~A~%~A~%## ~A~%~A~%## ~A~%~A~%"
          (quadlet-path) (quadlet-unit)
          (haproxy-backend-path) (haproxy-backend)
          *haproxy-host-map* (host-map-line)))

(defun main (argv)
  (when (member "--help" argv :test #'string=)
    (format t "~A~%" (usage))
    (return-from main 0))
  (let ((render-only (member "--render" argv :test #'string=))
        (args (remove "--render" argv :test #'string=)))
    (loop for (flag value) on args by #'cddr
          do (apply-option flag value))
    (when render-only
      (render)
      (return-from main 0))
    (deploy-navidrome)
    0))
