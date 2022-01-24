FROM imageflutterweb as builder
# FROM ubuntu:20.04 as builder

# RUN ln -snf /usr/share/zoneinfo/$CONTAINER_TIMEZONE /etc/localtime && echo $CONTAINER_TIMEZONE > /etc/timezone
# RUN apt-get update && apt-get install -y tzdata
# RUN apt-get install -y curl git wget unzip libgconf-2-4 gdb libstdc++6 libglu1-mesa fonts-droid-fallback lib32stdc++6 python3
# RUN apt-get clean

# # download Flutter SDK from Flutter Github repo
# RUN git clone https://github.com/flutter/flutter.git /usr/local/flutter

# # Set flutter environment path
# ENV PATH="/usr/local/flutter/bin:/usr/local/flutter/bin/cache/dart-sdk/bin:${PATH}"
# ENV DEBIAN_FRONTEND=noninteractive 

# # Run flutter doctor
# RUN flutter doctor

# # Enable flutter web
# RUN flutter channel master
# RUN flutter upgrade
# RUN flutter config --enable-web

# # Copy files to container and build
RUN mkdir /app/
# RUN mkdir /root/.pub-cache
COPY . /app/
COPY .pub-cache /root/.pub-cache
# VOLUME /home/jjchin/.pub-cache /root/.pub-cache
WORKDIR /app/
RUN flutter build web

# FROM nginx:1.21.1-alpine
# COPY --from=builder /app/build/web /usr/share/nginx/html

# pub get on docker file and pub get on container again not work maybe pub get different place
#copy cache to container OK
# mount while run docker OK
# ln -s /home/jjchin/.pub-cache /home/jjchin/testaction/.pub-cache