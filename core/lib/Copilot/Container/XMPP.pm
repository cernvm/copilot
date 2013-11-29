package Copilot::Container::XMPP;

=pod

=head1 NAME Copilot::Container::XMPP

=head1 DESCRIPTION

Container class for an XMPP  client. Copilot::Container::XMPP is a child of Copilot::Container class. This class allows to communicate messages via XMPP protocol

Please also see the documentation of Copilot::Container

=cut

=head1 METHODS


=item new($options)

Constructor for Copilot::Container::XMPP class. Takes as an input hash reference with options. The following options can be specified:

    Component        => Name of the component which must run in the container
    ComponentOptions => Hash reference with options which must be passed to the component.
    JabberID         => Jabber ID (username)
    JabberPassword   => Jabber password for authentication
    JabberDomain     => Jabber domain for which the ID is registered on the server
    JabberServer     => Jabber server hostname or IP
    JabberPort       => Jabber server port (optional, default is 5222)
    SecurityModule   => Name of the secutiry module to use
    SecurityOptions  => Hash reference with the options which must be passed to the components
    
Example usage:

    my $jm = new Copilot::Container::XMPP (
                                             {
                                                Component => 'JobManager',
                                                LoggerConfig => $loggerConfig,
                                                JabberID => $jabberID,
                                                JabberPassword => $jabberPassword,
                                                JabberDomain => $jabberDomain,
                                                JabberServer => $jabberServer,
                                                ComponentOptions => {
                                                                    ChirpDir => $chirpWorkDir ,
                                                                    AliEnUser => 'hartem',
                                                                    StorageManagerAddress => $storageManagerJID,
                                                                  },
                                                SecurityModule => 'Provider',
                                                SecurityOptions => {
                                                                    KMAddress => $keyServerJID,
                                                                    PublicKeysFile => '/home/hartem/copilot/copilot/etc/PublicKeys.txt',
                                                                    ComponentPublicKey => '/home/hartem/copilot/copilot/etc/keys/ja_key.pub',
                                                                    ComponentPrivateKey => '/home/hartem/copilot/copilot/etc/keys/ja_key.priv',
                                                                   },    
                                             }
                                        );

=cut





use strict;
use warnings;

use vars qw (@ISA);

use Copilot::Container;
use Copilot::Util;
use Copilot::GUID;

use POE;
use POE::Filter::Reference;
use POE::Component::Logger;

use POE::Component::Jabber;                   #include PCJ
use POE::Component::Jabber::Error;            #include error constants
use POE::Component::Jabber::Status;           #include status constants
use POE::Component::Jabber::ProtocolFactory;  #include connection type constants

use XML::SAX::Expat::Incremental; # explicit require (needed for rBuilder)

use MIME::Base64;

use Data::Dumper;



@ISA = ("Copilot::Container");

sub _init
{
    my $self    = shift;
    my $options = shift;

    #
    # Read config 
    $self->_loadConfig($options);

    #
    # Create logger
    POE::Component::Logger->spawn(ConfigFile => $self->{'LOGGER_CONFIG_FILE'});

    my $debugOptions = {};
    $self->{'DEBUG'} && ($debugOptions = { debug => 1, trace => 1});

    #
    # Create main POE session here. It will serve as a bridge between POE::Component::Jabber and the component 
    $self->{session} = POE::Session->create (
                                                options       => $debugOptions, #{ debug => 1, trace => 1},
                                                args          => [ $self ],
                                                inline_states => {
                                                                    _start                  => \&mainStartHandler,
                                                                    _stop                   => \&mainStopHandler,
                                                                    $self->{'LOG_HANDLER'}  => \&msgLogHandler,
                                                                    statusEvent             => \&pcjStatusEventHandler,
                                                                    errorEvent              => \&pcjErrorEventHandler,
                                                                    outputEvent             => \&pcjOutputEventHandler,
                                                                    inputEvent              => \&pcjInputEventHandler,
                                                                    reconnectEvent          => \&pcjReconnectEventHandler,
                                                                    componentWakeUp         => \&componentWakeUpHandler, # Event for waking the component up 
                                                                    $self->{'DELIVER_INPUT_HANDLER'} => \&componentDeliverInputHandler, # Event for delivering input to the component
                                                                    $self->{'DELIVER_OUTPUT_HANDLER'} => \&componentDeliverOutputHandler, # Event for delivering output from the component
                                                                    $self->{'SEND_HANDLER'} => \&componentSendHandler, # Event for sending messages to the outer world
                                                                    componentSendAck        => \&componentSendAckHandler,
#                                                                    $self->{'SEND_HANDLER'} => \&componentDeliverOutputHandler,
                                                                    processQueue            => \&mainProcessQueueHandler,
                                                                },
                                               
                                            ); 

    # Instantiate the component
    my $component = "Copilot::Component::".$self->{COMPONENT_NAME}; 
    eval " require $component";
    if ($@)
    {
        die "Failed to load $component : $@ \n";
    }
 
    $self->{'COMPONENT'} = $component->new(
                                        {
                                            'COMPONENT_NAME' => $self->{'COMPONENT_NAME'},
                                            'CONTAINER_ALIAS' => $self->{'MAIN_SESSION_ALIAS'},
                                            'CONTAINER_SEND_HANDLER' => $self->{'DELIVER_OUTPUT_HANDLER'},
                                            'COMPONENT_OPTIONS' => $options->{'ComponentOptions'},
                                            'SECURITY_OPTIONS' => $options->{'SecurityOptions'},
                                            'CONTAINER_LOG_HANDLER' => $self->{'LOG_HANDLER'},
                                        } 
                                      );

    
    # Instantiate the security module                                      
    if (defined ($self->{'SECURITY_MODULE'}))
    {    
        my $securityModule = "Copilot::Security::".$self->{'SECURITY_MODULE'};
        eval " require $securityModule";
        if ($@)
        {
            die "Failed to load security module $securityModule: $@\n";
        }
       
        $self->{'SECURITY'} = $securityModule->new (
                                                    {
                                                        'MODULE_NAME' => $self->{'SECURITY_MODULE'},
                                                        'CONTAINER_ALIAS' => $self->{'MAIN_SESSION_ALIAS'},
                                                        'CONTAINER_SEND_HANDLER' => $self->{'SEND_HANDLER'},
                                                        'SECURITY_OPTIONS' => $options->{'SecurityOptions'},
                                                        'CONTAINER_LOG_HANDLER' => $self->{'LOG_HANDLER'},
                                                        'CONTAINER_DELIVER_INPUT_HANDLER' => $self->{'DELIVER_INPUT_HANDLER'},
#                                                       'CONTAINER_DELIVER_OUTPUT_HANDLER' => $self->{'DELIVER_OUTPUT_HANDLER'},
                                                    }                
                                                   );
    }
                                        
    return $self;
}

#
# Loads config parameters into $self
sub _loadConfig
{
    my $self = shift;
    my $options = shift;

    # Component which will be running inside our server
    $self->{'COMPONENT_NAME'} = $options->{'Component'} || die "Component name not provided. Can not start the server.\n"; 
    
    # Will be used as an alias for POE::Component::Jabber
    $self->{'MAIN_SESSION_ALIAS'} = "Container_".$self->{'COMPONENT_NAME'};     

    # Event name which will be used to log messages
    $self->{'LOG_HANDLER'} = 'logger'; 

    # Event name which will be used to deliver input to the Component
    $self->{'DELIVER_INPUT_HANDLER'} = 'componentDeliverInput';
 
    # Event name which will be used to deliver input to the component
    $self->{'DELIVER_OUTPUT_HANDLER'} = 'componentDeliverOutput';
   
    # Event name which will be used in the component needs to send something 
    # to the outer world.
    $self->{'SEND_HANDLER'} =  'componentSend';

    # Logger configuration file
    $self->{'LOGGER_CONFIG_FILE'} = $options->{'LoggerConfig'} || die "Logger configuration file not provided. Can not start the server.\n";

    # Jabber ID, password and hostname 
    $self->{'JABBER_ID'}       = $options->{'JabberID'} || die "Jabber ID (username) is not provided.\n";
    $self->{'JABBER_DOMAIN'}   = $options->{'JabberDomain'} || die "Jabber domain is not provided\n";   
    $self->{'JABBER_PASSWORD'} = $options->{'JabberPassword'};
    $self->{'JABBER_RESOURCE'} = $options->{'JabberResource'}; 
    $self->{'JABBER_RESEND'}   = $options->{'JabberResend'};

    # Jabber server hostname (or IP) and port
    $self->{'JABBER_SERVER_ADDRESS'} = $options->{'JabberServer'} || die "Jabber server address is not provided";
    $self->{'JABBER_SERVER_PORT'}    = $options->{'JabberPort'} || "5222";

    # Security module name
    $self->{'SECURITY_MODULE'} = $options->{'SecurityModule'};

    $self->{'CONTAINER_CONNECTION'} = 0;

    # Debugging enabled
    $self->{'DEBUG'} = $options->{'Debug'} || "0";
}

#
# Start handler of the main POE session
sub mainStartHandler
{
    my ( $kernel, $heap, $self ) = @_[ KERNEL, HEAP, ARG0 ];

    $heap->{'self'} = $self;
    $kernel->alias_set($self->{'MAIN_SESSION_ALIAS'});

    my $debugOptions = '0';
    $self->{'DEBUG'} && ($debugOptions = '1');

    my $jabberOptions = {
                           IP               => $self->{'JABBER_SERVER_ADDRESS'},
                           Port             => $self->{'JABBER_SERVER_PORT'},
                           Username         => $self->{'JABBER_ID'},
                           Password         => $self->{'JABBER_PASSWORD'},
                           Hostname         => $self->{'JABBER_DOMAIN'}, 
                           Alias            => 'Jabber',
                           ConnectionType   => +XMPP, #+LEGACY ,
                           Debug            => $debugOptions, #'0',
                           States           => {
                                                StatusEvent => "statusEvent",
                                                InputEvent  => "inputEvent",
                                                ErrorEvent  => "errorEvent",
                                               },
                         };

   if (defined($self->{'JABBER_RESOURCE'}) && $self->{'JABBER_RESOURCE'} ne '')
   {
       $jabberOptions->{'Resource'} = $self->{'JABBER_RESOURCE'};
   }

   $heap->{'Jabber'} = POE::Component::Jabber->new( %$jabberOptions );

   $heap->{'GUID'} = new Copilot::GUID;    
   $heap->{'MessageQueue'} = {};

   $kernel->delay ('reconnectEvent', 1);
   $kernel->delay ('componentWakeUp', 2);
   if (defined($self->{'JABBER_RESEND'}) && $self->{'JABBER_RESEND'} eq '1')
   { 
      $kernel->delay ('processQueue', 1);
   }
}

#
# Stop handler of the main POE session
sub mainStopHandler
{
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];

    my $self = $heap->{'self'};

#    $kernel->state('reconnectEvent');
#    delete $heap->{'Jabber'};
    $kernel->post('Jabber', 'shutdown');
    $kernel->post ('Jabber', '_stop');
    $kernel->alias_remove($self->{'MAIN_SESSION_ALIAS'});
    
    #$kernel->stop();   
    #sleep 5 && exit 0;
}

sub pcjOutputEventHandler
{
    # This is our own output_event that is a simple passthrough on the way to
    # post()ing to PCJ's output_handler so it can then send the Node on to the
    # server
    my ( $kernel, $node, $sid ) =  @_[ KERNEL, HEAP, ARG0, ARG1 ];
    t d($node);
    $kernel->post( 'Jabber', 'output_handler', $node );

}

#
# Delivers output from component to the client
# Expects hash on input. Removes from hash 'from' and 'to' ('from' field is optional) fields, puts the rest of the elements to POE::Filter::XML::Node 
# and sends it 
sub componentDeliverOutputHandler
{
    my ($kernel, $heap, $output) = @_ [ KERNEL, HEAP, ARG0 ]; 

    my $self = $heap->{'self'};
    
    # Delay if we are not connected 
    if ($self->{'CONTAINER_CONNECTION'} == 0)
    {
        $kernel->delay ($self->{'DELIVER_OUTPUT_HANDLER'}, 2, $output);
        $kernel->yield ($self->{'LOG_HANDLER'}, 'Do not have a connection. Delaying output delivery.', 'warn');
        return;
    }
 
    my $handler = $self->{'SEND_HANDLER'};
 
    if (defined ($self->{'SECURITY'}))
    {
        my ($securityModule, $outputHandler) = ($self->{'SECURITY_MODULE'}, $self->{'SECURITY'}->getProcessOutputHandler());        
        $kernel->post ($securityModule, $outputHandler, $output);               
    }
    else
    {    
        $kernel->yield ($handler, $output);
    }
}

#
#
sub componentSendHandler
{
    my ($kernel, $heap, $output) = @_ [ KERNEL, HEAP, ARG0 ];
    
    my $self = $heap->{'self'}; 
    
    my $from = $output->{'from'} || $self->{'JABBER_ID'}.'@'.$self->{'JABBER_DOMAIN'};
    delete ($output->{'from'});

    my $to   = $output->{'to'};
    delete ($output->{'to'});

    # Append an ID
    my $GUID = $heap->{'GUID'};
    my $id = $GUID->CreateGuid();

   
    my $node = POE::Filter::XML::Node->new('message');
    $node->attr('from', $from);
    $node->attr('to', $to);  
    $node->attr('id', $id);  
    $node->insert_tag (Copilot::Util::hashToXMLNode ($output));
    
    if (defined($self->{'JABBER_RESEND'}) && $self->{'JABBER_RESEND'} eq '1')
    {
        # Enqueue the message 
        $heap->{'messageQueue'}->{$id} = {};
        $heap->{'messageQueue'}->{$id}->{'node'} = $node;
        $heap->{'messageQueue'}->{$id}->{'timestamp'} = time() + 60; # The other end has a minute to reply
        $heap->{'messageQueue'}->{$id}->{'trial'} = 1;
    }
    
    #$kernel->yield ($self->{'LOG_HANDLER'}, "Sending message to $to for the component (Msg ID:" . $id . ") MSG" . $node->to_str(), 'debug');
    $kernel->yield ($self->{'LOG_HANDLER'}, "Sending message to $to for the component (Msg ID:" . $id . ")", 'debug');
    $kernel->post ('Jabber', 'output_handler', $node);
}

#
#
sub mainProcessQueueHandler
{
    my ($kernel, $heap) = @_[ KERNEL, HEAP ];
    my $queue = $heap->{'messageQueue'};
    
    my $self = $heap->{'self'};
    
    my $now = time();
    foreach my $id (keys %$queue)
    {
        my $timestamp = $queue->{$id}->{'timestamp'};
        my $delta = $now - $timestamp;
        my $trial = $queue->{$id}->{'trial'};

        if ($delta > 24*3600) # give up after one day
        {
            delete $queue->{$id};
            $kernel->yield ($self->{'LOG_HANDLER'}, "Failed to deliver message (Msg ID: $id).  Removing from the queue ", 'warn');
        }            
        if ($delta > ($trial * 10)) # wait before resending 
        {
            # Try to send again 
            $queue->{$id}->{'trial'} *= 2;
            my $node = $queue->{$id}->{'node'};
            my $nodeHash = Copilot::Util::XMLNodeToHash($node);
            $kernel->yield ($self->{'LOG_HANDLER'}, "Resending '" . $nodeHash->{'body'}->{'info'}->{'command'} . "' to ". $nodeHash->{'to'} . " (Msg ID: $id)", 'info');
            $kernel->post ('Jabber', 'output_handler', $node);
        } 
    }

    $kernel->delay('processQueue', 1);
}

# This is the input event. We receive all data from the server through this
# event. ARG0 willi be a POE::Filter::XML::Node object. XML Node will be converted 
# to hash and will be passed to componentDeliverInput for delivery to the component.

sub pcjInputEventHandler
{

    my ( $kernel, $heap, $nodeXML ) = @_[ KERNEL, HEAP, ARG0 ];
    
    my $nodeType = $nodeXML->name();
    return if (($nodeType eq 'presence') or ($nodeType eq 'stream:stream'));

    my $nodeHash = Copilot::Util::XMLNodeToHash ($nodeXML);
    my $self = $heap->{'self'};

    my $from = $nodeHash->{'from'};     
   
    if (defined ($self->{'SECURITY'}))
    {
        my ($securityModule, $inputHandler) = ($self->{'SECURITY_MODULE'}, $self->{'SECURITY'}->getProcessInputHandler());        
        $kernel->post ($securityModule, $inputHandler, $nodeHash) ;
    }
    else
    {
        my $handler =  $self->{'DELIVER_INPUT_HANDLER'};
        $kernel->yield ($handler, $nodeHash);
    }

    
}

sub componentSendAckHandler
{
    my ($kernel, $heap, $to, $from, $id) = @_[KERNEL, HEAP, ARG0, ARG1, ARG2];

    my $self = $heap->{'self'};

    my $node = POE::Filter::XML::Node->new('message');
    $node->attr('from', $from);
    $node->attr('to', $to);  
    $node->attr('ack', $id);  
    
    $kernel->yield ($self->{'LOG_HANDLER'}, "Sending ACK message to $to (from $from) for the messages ID:" . $id . ")", 'debug');   
    $kernel->post ('Jabber', 'output_handler', $node);
}
    

# Delvers input from client to the component 
sub componentDeliverInputHandler
{
    my ($heap, $kernel, $sender, $input) = @_[ HEAP, KERNEL, SESSION, ARG0];
    my $self = $heap->{'self'};

    my ($componentAlias, $handler ) = ($self->{'COMPONENT_NAME'}, $self->{'COMPONENT'}->getInputHandler() );
    

    # Check if it is the error message
    my $error = $input->{'error'};
    if ((defined $error) && ($input->{'type'} eq 'error'))
    {
        if ( defined($error->{'service-unavailable'}) )
        {
            my $from = $input->{'from'};
            $kernel->yield($self->{'LOG_HANDLER'}, "$from seems to be offline. Will retry.");
            return; 
        }      
        else
        {
            my $errorDump = Dumper $error;
            $kernel->yield($self->{'LOG_HANDLER'}, 'Got an error message. Code: '. $error->{'code'}, 'warn');
            $kernel->yield($self->{'LOG_HANDLER'}, "Error message dump: $errorDump", 'debug');
            return; 
        }
    }

    # Check if this is an ACK message
    my $ackId = $input->{'ack'};
    if (defined $ackId)
    {
        if (defined ($self->{'JABBER_RESEND'}) && $self->{'JABBER_RESEND'} eq '1')
        {
            delete $heap->{'messageQueue'}->{$ackId};
        }
        $kernel->yield($self->{'LOG_HANDLER'}, 'Got ACK for ' . $ackId, 'debug');       
        return;
    }     

    my $msgForComponent = $input->{'body'}->{'info'};
    if (ref ($msgForComponent) eq 'HASH')
    {
        $msgForComponent->{'from'} = $input->{'from'};
        $msgForComponent->{'to'} = $input->{'to'};	

        # Send ack for this message
        my $id = $input->{'id'};
        if (defined $id)
        { 
            # Make sure that we process messages only once
            if (defined($heap->{'processedMessagesQueue'}->{$id}))
            {
                $kernel->yield($self->{'LOG_HANDLER'}, "The message with ID: $id has already been processed. Ignoring", 'debug');
            }
            else
            { 
                    $heap->{'processedMessagesQueue'}->{$id} = 1;
                    $kernel->yield($self->{'LOG_HANDLER'}, "Got msg with ID: $id from " . $msgForComponent->{'from'}, 'debug');  
                    my $to = $msgForComponent->{'from'};
                    my $from = $msgForComponent->{'to'}; 

                    $kernel->yield('componentSendAck', $to , $from, $id);

                    # Dispatch the input message to the component
                    $kernel->post ($componentAlias, $handler, $msgForComponent);
            } 
        }
        else 
        {
            my $msgDump = Dumper $input;
            $kernel->yield($self->{'LOG_HANDLER'}, "Got the message without ID. Ignoring. $msgDump", 'debug');
        }                  
    }
    else
    { 
        $kernel->yield($self->{'LOG_HANDLER'}, "Got malformed message:\n". Dumper $input , 'error');       
    }
}


#
# Reconnect handler
sub pcjReconnectEventHandler
{
    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
    $kernel->post('Jabber','reconnect');
}

# The status event receives all of the various bits of status from PCJ. PCJ
# sends out numerous statuses to inform the consumer of events of what it is
# currently doing (ie. connecting, negotiating TLS or SASL, etc). A list of
# these events can be found in PCJ::Status.
sub pcjStatusEventHandler
{
    my ( $kernel, $sender, $heap, $state ) =  @_[ KERNEL, SENDER, HEAP, ARG0 ];
    my $self = $heap->{'self'};

    if ( $state == +PCJ_INIT_FINISHED ) 
    {
          $kernel->post( 'Jabber', 'output_handler',POE::Filter::XML::Node->new('presence') );

          # And here is the purge_queue. This is to make sure we haven't sent
          # nodes while something catastrophic has happened (like reconnecting).

          $kernel->post( 'Jabber', 'purge_queue' );
          $self->{'CONTAINER_CONNECTION'} = 1;        
    }
}

# This is the error event. Any error conditions that arise from any point
# during connection or negotiation to any time during normal operation will be
# send to this event from PCJ. For a list of possible error events and exported
# constants, please see PCJ::Error
sub pcjErrorEventHandler
{
    my ( $kernel, $heap, $error ) = @_[ KERNEL, HEAP, ARG0 ];
    my $self = $heap->{'self'};    
    $self->{'CONTAINER_CONNECTION'} = 0;    
                
    if ( $error == +PCJ_SOCKETFAIL ) {
        my ( $call, $code, $err ) = @_[ ARG1 .. ARG3 ];
        #print "Socket error: $call, $code, $err\n";
        $kernel->delay( 'reconnectEvent', 1);
    }
    elsif ( $error == +PCJ_SOCKETDISCONNECT ) {
        #print "We got disconneted\n";
        $kernel->delay( 'reconnectEvent', 1);
    }
    elsif ( $error == +PCJ_CONNECTFAIL ) {
        print "Connect failed\n";
        $kernel->delay( 'reconnectEvent', 1);
    }
    elsif ( $error == +PCJ_SSLFAIL ) {
        print "TLS/SSL negotiation failed\n";
    }
    elsif ( $error == +PCJ_AUTHFAIL ) {
        print "Failed to authenticate\n";
    }
    elsif ( $error == +PCJ_BINDFAIL ) {
        print "Failed to bind a resource\n";
        $kernel->delay( 'reconnectEvent', 1);
    }
    elsif ( $error == +PCJ_SESSIONFAIL ) {
        print "Failed to establish a session\n";
        $kernel->delay( 'reconnectEvent', 1);
    }
    else {
        print "Unkown error detected. Trying to reconnect to XMPP server\n";
        $kernel->delay( 'reconnectEvent', 1);
    }
}


#
# internal event for waking the component up
sub componentWakeUpHandler
{

    my ($heap, $kernel) = @_[HEAP, KERNEL];
    my $self = $heap->{'self'};
    

    # wake the component up
    
    # Delay if we are not connected 
    if ( $self->{'CONTAINER_CONNECTION'} == 0 )
    {
        $kernel->delay('componentWakeUp', 2);
        $kernel->yield($self->{'LOG_HANDLER'}, 'Do not have a connection. Delaying component wakeup.', 'warn');
        return;
    }
    
    my ($componentAlias, $wakeUpHandler );
   
    eval { ($componentAlias, $wakeUpHandler ) = ($self->{'COMPONENT_NAME'}, $self->{'COMPONENT'}->getWakeUpHandler() ) };

    if ($@)
    {
        $kernel->yield($self->{'LOG_HANDLER'}, 'The component does not need to be waken up.', 'info');
    }
    else
    {
        $kernel->yield($self->{'LOG_HANDLER'}, 'Waking the component up.', 'info');
        $kernel->post ($componentAlias, $wakeUpHandler);
    }

    # wake the security module up
    my ($securityModuleAlias, $securityModuleWakeUpHandler);

    eval { ($securityModuleAlias, $securityModuleWakeUpHandler) = ($self->{'SECURITY_MODULE'}, $self->{'SECURITY'}->getWakeUpHandler)};
   
    if ($@)
    {
        $kernel->yield ($self->{'LOG_HANDLER'}, 'The security module does not need to be waken up.');
        return;
    }

    $kernel->yield ($self->{'LOG_HANDLER'}, 'Wake the security module up.');
    $kernel->post ($securityModuleAlias, $securityModuleWakeUpHandler);
}

sub msgLogHandler
{
    my ($heap, $msg) = @_[HEAP, ARG0]; 
    my $self = $heap->{'self'};

    my $logLevel = $_[ARG1] || "info";

    
    Logger->log (  {
                     level => $logLevel, 
                     message => $msg."\n",
                   }
                );
}

"M";

