package server

import (
	"testing"

	"github.com/thanhan92f1/proxmox-template/internal/executor"
	"github.com/thanhan92f1/proxmox-template/internal/reporter"
)

func TestShouldAutoDisableAfterProvision(t *testing.T) {
	tests := []struct {
		name   string
		result *executor.TaskResult
		want   bool
	}{
		{
			name:   "nil result",
			result: nil,
			want:   false,
		},
		{
			name: "failed provision",
			result: &executor.TaskResult{
				Status: reporter.StatusFailed,
			},
			want: false,
		},
		{
			name: "successful provision",
			result: &executor.TaskResult{
				Status: reporter.StatusSuccess,
			},
			want: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := shouldAutoDisableAfterProvision(tt.result); got != tt.want {
				t.Fatalf("shouldAutoDisableAfterProvision() = %v, want %v", got, tt.want)
			}
		})
	}
}
