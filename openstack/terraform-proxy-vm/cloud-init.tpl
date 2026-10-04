#cloud-config
package_update: true
packages:
  - nginx

write_files:
  - path: /etc/nginx/conf.d/proxy.conf
    permissions: "0644"
    owner: root:root
    content: |
      upstream openstudio_backend {
      ${upstream_servers}
      }

      server {
          listen 80 default_server;
          listen [::]:80 default_server;
          server_name _;

          location / {
              proxy_pass http://openstudio_backend;
              proxy_http_version 1.1;
              proxy_set_header Host $host;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "";
              proxy_send_timeout 600s;
              proxy_read_timeout 600s;
              client_max_body_size 0;
          }
      }

runcmd:
  - setsebool -P httpd_can_network_connect 1
  - systemctl enable nginx
  - systemctl restart nginx
