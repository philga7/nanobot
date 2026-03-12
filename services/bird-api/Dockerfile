FROM node:20-slim

WORKDIR /app

RUN npm install -g @steipete/bird@0.8.0

COPY package.json ./
RUN npm install --omit=dev

COPY index.js ./

EXPOSE 18791

ENV PORT=18791

CMD ["npm", "start"]
