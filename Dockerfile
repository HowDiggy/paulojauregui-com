# Build stage
FROM ghcr.io/gohugoio/hugo:latest AS builder

# Set working directory
WORKDIR /src

# Copy source files
COPY . .

# Fix permissions and build the website
RUN chmod -R 777 /src && \
    hugo --config hugo.toml --minify

# Production stage
FROM nginx:1.23-alpine

# Copy the built site from the builder stage
COPY --from=builder /src/public /usr/share/nginx/html

# Copy custom nginx config if needed
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/

# Expose port 80
EXPOSE 80

# Run nginx
CMD ["nginx", "-g", "daemon off;"]
