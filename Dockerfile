FROM ruby:2.7.0

RUN gem install nomad
RUN gem install net-ssh -v 5.2.0
RUN gem install net-ssh-gateway -v 2.0.0
RUN gem install ed25519
RUN gem install bcrypt_pbkdf

COPY *.rb /
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
