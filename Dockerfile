FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --production 2>/dev/null; true

COPY . .

EXPOSE ${PORT:-1080}

CMD ["node", "server.js"]
