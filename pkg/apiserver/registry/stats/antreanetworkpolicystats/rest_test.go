// Copyright 2020 Antrea Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package antreanetworkpolicystats

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"k8s.io/apimachinery/pkg/apis/meta/internalversion"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apiserver/pkg/endpoints/request"
	featuregatetesting "k8s.io/component-base/featuregate/testing"

	statsv1alpha1 "github.com/vmware-tanzu/antrea/pkg/apis/stats/v1alpha1"
	"github.com/vmware-tanzu/antrea/pkg/features"
)

type fakeStatsProvider struct {
	stats map[string]map[string]statsv1alpha1.AntreaNetworkPolicyStats
}

func (p *fakeStatsProvider) ListAntreaNetworkPolicyStats(namespace string) []statsv1alpha1.AntreaNetworkPolicyStats {
	var list []statsv1alpha1.AntreaNetworkPolicyStats
	if namespace == "" {
		for _, m1 := range p.stats {
			for _, m2 := range m1 {
				list = append(list, m2)
			}
		}
	} else {
		m1, _ := p.stats[namespace]
		for _, m2 := range m1 {
			list = append(list, m2)
		}
	}
	return list
}

func (p *fakeStatsProvider) GetAntreaNetworkPolicyStats(namespace, name string) (*statsv1alpha1.AntreaNetworkPolicyStats, bool) {
	m, exists := p.stats[namespace][name]
	if !exists {
		return nil, false
	}
	return &m, true
}

func TestRESTGet(t *testing.T) {
	tests := []struct {
		name                      string
		networkPolicyStatsEnabled bool
		antreaPolicyEnabled       bool
		stats                     map[string]map[string]statsv1alpha1.AntreaNetworkPolicyStats
		npNamespace               string
		npName                    string
		expectedObj               runtime.Object
		expectedErr               bool
	}{
		{
			name:                      "NetworkPolicyStats feature disabled",
			networkPolicyStatsEnabled: false,
			antreaPolicyEnabled:       true,
			expectedErr:               true,
		},
		{
			name:                      "AntreaPolicy feature disabled",
			networkPolicyStatsEnabled: true,
			antreaPolicyEnabled:       false,
			expectedErr:               true,
		},
		{
			name:                      "np not found",
			networkPolicyStatsEnabled: true,
			antreaPolicyEnabled:       true,
			stats: map[string]map[string]statsv1alpha1.AntreaNetworkPolicyStats{
				"foo": {
					"bar": {
						ObjectMeta: metav1.ObjectMeta{
							Namespace: "foo",
							Name:      "foo",
						},
					},
				},
			},
			npNamespace: "non existing namespace",
			npName:      "non existing name",
			expectedErr: true,
		},
		{
			name:                      "np found",
			networkPolicyStatsEnabled: true,
			antreaPolicyEnabled:       true,
			stats: map[string]map[string]statsv1alpha1.AntreaNetworkPolicyStats{
				"foo": {
					"bar": {
						ObjectMeta: metav1.ObjectMeta{
							Namespace: "foo",
							Name:      "bar",
						},
					},
				},
			},
			npNamespace: "foo",
			npName:      "bar",
			expectedObj: &statsv1alpha1.AntreaNetworkPolicyStats{
				ObjectMeta: metav1.ObjectMeta{
					Namespace: "foo",
					Name:      "bar",
				},
			},
			expectedErr: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			defer featuregatetesting.SetFeatureGateDuringTest(t, features.DefaultFeatureGate, features.NetworkPolicyStats, tt.networkPolicyStatsEnabled)()
			defer featuregatetesting.SetFeatureGateDuringTest(t, features.DefaultFeatureGate, features.AntreaPolicy, tt.antreaPolicyEnabled)()

			r := &REST{
				statsProvider: &fakeStatsProvider{stats: tt.stats},
			}
			ctx := request.WithNamespace(context.TODO(), tt.npNamespace)
			actualObj, err := r.Get(ctx, tt.npName, &metav1.GetOptions{})
			if tt.expectedErr {
				require.Error(t, err)
			} else {
				require.NoError(t, err)
			}
			assert.Equal(t, tt.expectedObj, actualObj)
		})
	}
}

func TestRESTList(t *testing.T) {
	tests := []struct {
		name                      string
		networkPolicyStatsEnabled bool
		antreaPolicyEnabled       bool
		stats                     map[string]map[string]statsv1alpha1.AntreaNetworkPolicyStats
		npNamespace               string
		expectedObj               runtime.Object
		expectedErr               bool
	}{
		{
			name:                      "NetworkPolicyStats feature disabled",
			networkPolicyStatsEnabled: false,
			antreaPolicyEnabled:       true,
			expectedErr:               true,
		},
		{
			name:                      "AntreaPolicy feature disabled",
			networkPolicyStatsEnabled: true,
			antreaPolicyEnabled:       false,
			expectedErr:               true,
		},
		{
			name:                      "all namespaces",
			networkPolicyStatsEnabled: true,
			antreaPolicyEnabled:       true,
			stats: map[string]map[string]statsv1alpha1.AntreaNetworkPolicyStats{
				"foo": {
					"bar": {
						ObjectMeta: metav1.ObjectMeta{
							Namespace: "foo",
							Name:      "bar",
						},
					},
				},
				"foo1": {
					"bar1": {
						ObjectMeta: metav1.ObjectMeta{
							Namespace: "foo1",
							Name:      "bar1",
						},
					},
				},
			},
			npNamespace: "",
			expectedObj: &statsv1alpha1.AntreaNetworkPolicyStatsList{
				Items: []statsv1alpha1.AntreaNetworkPolicyStats{
					{
						ObjectMeta: metav1.ObjectMeta{
							Namespace: "foo",
							Name:      "bar",
						},
					},
					{
						ObjectMeta: metav1.ObjectMeta{
							Namespace: "foo1",
							Name:      "bar1",
						},
					},
				},
			},
			expectedErr: false,
		},
		{
			name:                      "one namespace",
			networkPolicyStatsEnabled: true,
			antreaPolicyEnabled:       true,
			stats: map[string]map[string]statsv1alpha1.AntreaNetworkPolicyStats{
				"foo": {
					"bar": {
						ObjectMeta: metav1.ObjectMeta{
							Namespace: "foo",
							Name:      "bar",
						},
					},
				},
				"foo1": {
					"bar1": {
						ObjectMeta: metav1.ObjectMeta{
							Namespace: "foo1",
							Name:      "bar1",
						},
					},
				},
			},
			npNamespace: "foo",
			expectedObj: &statsv1alpha1.AntreaNetworkPolicyStatsList{
				Items: []statsv1alpha1.AntreaNetworkPolicyStats{
					{
						ObjectMeta: metav1.ObjectMeta{
							Namespace: "foo",
							Name:      "bar",
						},
					},
				},
			},
			expectedErr: false,
		},
		{
			name:                      "empty stats",
			networkPolicyStatsEnabled: true,
			antreaPolicyEnabled:       true,
			stats:                     map[string]map[string]statsv1alpha1.AntreaNetworkPolicyStats{},
			npNamespace:               "",
			expectedObj: &statsv1alpha1.AntreaNetworkPolicyStatsList{
				Items: []statsv1alpha1.AntreaNetworkPolicyStats{},
			},
			expectedErr: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			defer featuregatetesting.SetFeatureGateDuringTest(t, features.DefaultFeatureGate, features.NetworkPolicyStats, tt.networkPolicyStatsEnabled)()
			defer featuregatetesting.SetFeatureGateDuringTest(t, features.DefaultFeatureGate, features.AntreaPolicy, tt.antreaPolicyEnabled)()

			r := &REST{
				statsProvider: &fakeStatsProvider{stats: tt.stats},
			}
			ctx := request.WithNamespace(context.TODO(), tt.npNamespace)
			actualObj, err := r.List(ctx, &internalversion.ListOptions{})
			if tt.expectedErr {
				require.Error(t, err)
			} else {
				require.NoError(t, err)
			}
			if tt.expectedObj == nil {
				assert.Nil(t, actualObj)
			} else {
				assert.ElementsMatch(t, tt.expectedObj.(*statsv1alpha1.AntreaNetworkPolicyStatsList).Items, actualObj.(*statsv1alpha1.AntreaNetworkPolicyStatsList).Items)
			}
		})
	}
}
