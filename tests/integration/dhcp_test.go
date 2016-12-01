/*
Copyright 2016 Mirantis

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package integration

import (
	"log"
	"net"
	"os/exec"
	"strings"
	"testing"

	"github.com/containernetworking/cni/pkg/ns"
	"github.com/containernetworking/cni/pkg/types"
	"github.com/vishvananda/netlink"

	"github.com/Mirantis/virtlet/pkg/dhcp"
	"github.com/Mirantis/virtlet/pkg/nettools"
)

func runDhcp(serverNS ns.NetNS, config *dhcp.Config) (*dhcp.Server, chan struct{}) {
	var server *dhcp.Server
	readyCh := make(chan struct{})
	doneCh := make(chan struct{})
	go func() {
		serverNS.Do(func(ns.NetNS) error {
			server = dhcp.NewServer(config)
			if err := server.SetupListener("0.0.0.0"); err != nil {
				log.Panicf("failed to setup dhcp listener: %v", err)
			}

			close(readyCh)
			server.Serve()
			close(doneCh)
			return nil
		})
	}()

	// make sure we can close the server
	<-readyCh
	return server, doneCh
}

type dhcpTestCase struct {
	config             dhcp.Config
	expectedSubstrings []string
}

func runDhcpTestCase(t *testing.T, testCase *dhcpTestCase) {
	serverNS, err := ns.NewNS()
	if err != nil {
		t.Fatalf("Failed to create ns for dhcp server: %v", err)
	}
	defer serverNS.Close()
	clientNS, err := ns.NewNS()
	if err != nil {
		t.Fatalf("Failed to create ns for dhcp client: %v", err)
	}
	defer clientNS.Close()
	var clientVeth, serverVeth netlink.Link
	serverNS.Do(func(ns.NetNS) error {
		serverVeth, clientVeth, err = nettools.CreateEscapeVethPair(clientNS, "veth0", 1500)
		if err != nil {
			t.Fatalf("failed to create escape veth pair: %v", err)
		}
		addr, err := netlink.ParseAddr("169.254.254.2/24")
		if err != nil {
			t.Fatal("failed to parse dhcp interface address")
		}
		if err = netlink.AddrAdd(serverVeth, addr); err != nil {
			t.Fatalf("failed to add addr for serverVeth: %v", err)
		}

		return nil
	})

	config := testCase.config
	config.PeerHardwareAddress = clientVeth.Attrs().HardwareAddr
	server, doneCh := runDhcp(serverNS, &config)
	defer func() {
		server.Close()
		<-doneCh
	}()

	clientNS.Do(func(ns.NetNS) error {
		out, err := exec.Command("dhcpcd", "-T").CombinedOutput()
		if err != nil {
			t.Errorf("dhcpcd failed: %v\nout:\n%s", err, out)
			return nil
		}
		outStr := string(out)
		var missing []string
		for _, str := range testCase.expectedSubstrings {
			if !strings.Contains(outStr, str) {
				missing = append(missing, str)
			}
		}
		if len(missing) != 0 {
			t.Errorf("some of the substrings are missing from dhcpcd output:\n%s\n--- Full output:\n%s",
				strings.Join(missing, "\n"), out)
		}
		return nil
	})
}

func TestDhcpServer(t *testing.T) {
	testCases := []*dhcpTestCase{
		{
			config: dhcp.Config{
				CNIResult: types.Result{
					IP4: &types.IPConfig{
						IP: net.IPNet{
							IP:   net.IP{10, 1, 90, 5},
							Mask: net.IPMask{255, 255, 255, 0},
						},
						Gateway: net.IP{10, 1, 90, 1},
						Routes: []types.Route{
							{
								Dst: net.IPNet{
									IP:   net.IP{10, 10, 42, 0},
									Mask: net.IPMask{255, 255, 255, 0},
								},
								GW: net.IP{10, 1, 90, 90},
							},
						},
					},
				},
			},
			expectedSubstrings: []string{
				"new_broadcast_address='10.1.90.255'",
				"new_classless_static_routes='10.10.42.0/24 10.1.90.90'",
				"new_dhcp_lease_time='86400'",
				"new_dhcp_rebinding_time='64800'",
				"new_dhcp_renewal_time='43200'",
				"new_dhcp_server_identifier='169.254.254.2'",
				"new_domain_name_servers='8.8.8.8'",
				"new_ip_address='10.1.90.5'",
				"new_network_number='10.1.90.0'",
				"new_routers='10.1.90.1'",
				"new_subnet_cidr='24'",
				"new_subnet_mask='255.255.255.0'",
				"veth0: offered 10.1.90.5 from 169.254.254.2",
			},
		},
		{
			config: dhcp.Config{
				CNIResult: types.Result{
					IP4: &types.IPConfig{
						IP: net.IPNet{
							IP:   net.IP{10, 1, 90, 5},
							Mask: net.IPMask{255, 255, 255, 0},
						},
						Gateway: net.IP{169, 254, 1, 1},
						Routes: []types.Route{
							{
								Dst: net.IPNet{
									IP:   net.IP{169, 254, 1, 1},
									Mask: net.IPMask{255, 255, 255, 255},
								},
								GW: nil,
							},
						},
					},
					DNS: types.DNS{
						Nameservers: []string{"10.1.90.99"},
					},
				},
			},
			expectedSubstrings: []string{
				"new_broadcast_address='10.1.90.255'",
				"new_classless_static_routes='169.254.1.1/32 0.0.0.0'",
				"new_dhcp_lease_time='86400'",
				"new_dhcp_rebinding_time='64800'",
				"new_dhcp_renewal_time='43200'",
				"new_dhcp_server_identifier='169.254.254.2'",
				"new_domain_name_servers='10.1.90.99'",
				"new_ip_address='10.1.90.5'",
				"new_network_number='10.1.90.0'",
				"new_routers='169.254.1.1'",
				"new_subnet_cidr='24'",
				"new_subnet_mask='255.255.255.0'",
				"veth0: offered 10.1.90.5 from 169.254.254.2",
			},
		},
	}

	for _, testCase := range testCases {
		// TODO: use subtests https://golang.org/pkg/testing/#hdr-Subtests_and_Sub_benchmarks
		// (need newer Go)
		runDhcpTestCase(t, testCase)
	}
}

// TODO use code like dhcp4.NewSnooperConn() to catch escaping dhcp packets
