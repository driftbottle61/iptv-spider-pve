package auth

import "iptv-spider-sh/modules/http_client"

type ClientOption func(*Client)

func WithUserAgent(ua string) ClientOption {
	return func(c *Client) {
		c.userAgent = ua
	}
}

func With4kLogAuthAddr(addr string) ClientOption {
	return func(c *Client) {
		c.pre4kLogAuthAddr = addr
	}
}

func WithSTBType(stbType string) ClientOption {
	return func(c *Client) {
		c.stbType = stbType
	}
}

func WithHTTPClientLocalAddr(addr string) ClientOption {
	return func(c *Client) {
		c.httpClient = http_client.NewHttpClient(
			http_client.WithUserAgent(c.userAgent),
			http_client.WithLocalAddr(addr),
		)
	}
}
