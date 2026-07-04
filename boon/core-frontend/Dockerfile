# Dev-server image for core-frontend (Vue 3 + Vite). Not for production —
# production would build static assets and serve them via nginx directly.

FROM node:22-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .

EXPOSE 5173

CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0", "--port", "5173"]
