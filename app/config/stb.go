package config

type Stb struct {
	SN            string `mapstructure:"sn" json:"sn" yaml:"sn"`
	UID           string `mapstructure:"uid" json:"uid" yaml:"uid"`
	MAC           string `mapstructure:"mac" json:"mac" yaml:"mac"`
	IP            string `mapstructure:"ip" json:"ip" yaml:"ip"`
	Type          string `mapstructure:"type" json:"type" yaml:"type"`
	AuthHost      string `mapstructure:"auth_host" json:"auth_host" yaml:"auth_host"`
	PlaneAIP      string `mapstructure:"plane_a_ip" json:"plane_a_ip" yaml:"plane_a_ip"`
	PlaneBGateway string `mapstructure:"plane_b_gateway" json:"plane_b_gateway" yaml:"plane_b_gateway"`
}
