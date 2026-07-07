FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --production 2>/dev/null; true

COPY . .

EXPOSE 7777
EXPOSE 3000

CMD ["node", "server.js"]
