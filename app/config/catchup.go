package config

type Catchup struct {
	SourceM3u    string   `mapstructure:"source_m3u" json:"source_m3u" yaml:"source_m3u"`
	Udpxy        string   `mapstructure:"udpxy" json:"udpxy" yaml:"udpxy"`
	Days         int      `mapstructure:"days" json:"days" yaml:"days"`
	RelayClients []string `mapstructure:"relay_clients" json:"relay_clients" yaml:"relay_clients"`
}
