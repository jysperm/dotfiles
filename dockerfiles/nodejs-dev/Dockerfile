FROM ubuntu:14.04

RUN sed -i 's/archive.ubuntu.com/mirrors.ustc.edu.cn/g' /etc/apt/sources.list

RUN echo "Asia/Shanghai" > /etc/timezone
RUN dpkg-reconfigure -f noninteractive tzdata

RUN apt-get update
RUN apt-get install -y curl
RUN curl -sL https://deb.nodesource.com/setup_4.x | bash -
RUN apt-get install -y nodejs daemon git python build-essential
RUN npm install -g cnpm --registry=https://registry.npm.taobao.org
RUN cnpm install -g hexo http-server nodemon coffee-script mocha gulp

WORKDIR /root
CMD ["node"]
