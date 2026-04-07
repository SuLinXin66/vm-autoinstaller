package hostinfo

import (
	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/mem"
)

type HostInfo struct {
	LogicalCPUs   int
	TotalMemoryMB uint64
}

func Get() (*HostInfo, error) {
	cores, err := cpu.Counts(true)
	if err != nil {
		return nil, err
	}
	vm, err := mem.VirtualMemory()
	if err != nil {
		return nil, err
	}
	return &HostInfo{
		LogicalCPUs:   cores,
		TotalMemoryMB: vm.Total / 1024 / 1024,
	}, nil
}

func DiskAvailGB(path string) (uint64, error) {
	usage, err := disk.Usage(path)
	if err != nil {
		return 0, err
	}
	return usage.Free / 1024 / 1024 / 1024, nil
}
