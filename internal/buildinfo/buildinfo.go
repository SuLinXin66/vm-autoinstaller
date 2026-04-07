package buildinfo

var (
	AppName = "kvm-ubuntu"
	RepoURL = ""
	Branch  = "main"
	Version = "dev"

	DefaultVMName             = "ubuntu-server"
	DefaultVMCPUs             = "0"
	DefaultVMMemory           = "2048"
	DefaultVMDiskSize         = "20"
	DefaultVMUser             = "wpsweb"
	DefaultUbuntuVersion      = "24.04"
	DefaultNetworkMode        = "nat"
	DefaultBridgeName         = "br0"
	DefaultUbuntuImageBaseURL = "https://cloud-images.ubuntu.com/releases"
	DefaultAutoYes            = "0"
	DefaultEnforceResourceLimit = "1"
)
