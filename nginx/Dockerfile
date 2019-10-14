FROM nginx:latest

# Add custom configuration
COPY config /etc/nginx

# Add 'wait-for-it' to check upstream availability
COPY wait-for-it.sh /usr/local/bin/wait-for-it
RUN chmod +x /usr/local/bin/wait-for-it

# Add entrypoint script
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

ENTRYPOINT ["docker-entrypoint"]
CMD ["nginx", "-g", "daemon off;"]