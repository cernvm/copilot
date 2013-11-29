package Copilot::Util;

use strict;

use Data::Dumper;
use XML::Simple;

use POE::Filter::XML::Node;
use MIME::Base64;



=pod

=head1 NAME Copilot::Util

A package which contains different utility functions


=cut

=head1 FUNCTIONS


=item hashToXMLNode()

Converts perl hash to POE::Filter::XML::Node object 

=cut 

sub hashToXMLNode
{   
    my $h = shift;
    my $name = shift || "body";

    my $node = POE::Filter::XML::Node->new($name);

    foreach my $key (keys %$h) 
    {   
        my $value = $h->{$key};
        if (ref($value) eq 'HASH')
        {   
            my $child = hashToXMLNode ( $value, $key);
            $node->insert_tag ($child);
            next;
        }

        # append '_BASE64' before encoded string
        $node->attr ($key, "_BASE64:".encode_base64($value));
    }

    return $node;
}

=item XMLNodeToHash()

Converts POE::Filter::XML::Node object to perl hash 

=cut

sub XMLNodeToHash
{   
    my $node = shift;
    my $hr = {};

    $hr = $node->get_attrs();

    foreach my $key (keys %$hr)
    {   
        # check if the value needs to be Base64 decoded (in hashToXMLNode we append '_BASE64' before encoded string) 
        $hr->{$key} =~ s/(^_BASE64)//;
        $1 or next;

        $hr->{$key} = decode_base64 ($hr->{$key}); 
    }
 
    my $children = $node->get_children();

    foreach my $child (@$children)
    {   
        my $name = $child->name();
        $hr->{$name} = XMLNodeToHash ($child);
    }
  
    return $hr;
}

=item XMLStringToHash

Converts an XML string to hash

=cut

sub XMLStringToHash
{
    my $string = shift;     
    my $xm = new XML::Simple;
    $XML::Simple::PREFERRED_PARSER="XML::Parser";
    return $xm->XMLin ($string);
}    

=item decodeBase64Hash

Base64 decodes the values of the hash

=cut

sub decodeBase64Hash
{
    my $hashRefBase64 = shift;
    my $hashRefDecoded = {};   
    
    foreach my $key (keys %$hashRefBase64)
    {
        my $value = $hashRefBase64->{$key};
        if (ref ($value) eq 'HASH')
        {
            $hashRefDecoded->{$key} = decodeBase64Hash ($value);            
            next;            
        }
        
        $value =~ s/(^_BASE64)//; 
        $1 and ($value = decode_base64($value));
        $hashRefDecoded->{$key} = $value;       
    }
    
    return $hashRefDecoded;
}

"M";
