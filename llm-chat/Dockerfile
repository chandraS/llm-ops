FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json ./
RUN npm install
COPY . .
ARG VITE_API_URL=https://llm-ops.akamai-poc.online
ARG VITE_MODEL=qwen25-7b
ENV VITE_API_URL=$VITE_API_URL
ENV VITE_MODEL=$VITE_MODEL
RUN npm run build

FROM nginx:stable-alpine
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
