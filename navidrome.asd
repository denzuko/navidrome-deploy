;;;; navidrome.asd -- umbrella namespace for the Navidrome deployment stack.

(defsystem "navidrome"
  :description "Umbrella for the navidrome-deploy stack. Empty on purpose;
load a slash subsystem instead."
  :author "Dwight Spencer"
  :license "BSD-3-Clause"
  :version "0.1.0")

(defsystem "navidrome/deploy"
  :description "Consfigurator provisioning for Navidrome on rootless Podman
quadlets, encrypted ZFS, and HAProxy."
  :author "Dwight Spencer"
  :license "BSD-3-Clause"
  :version "0.1.0"
  :depends-on ("consfigurator" "uiop")
  :pathname "src"
  :components ((:file "deploy")))
