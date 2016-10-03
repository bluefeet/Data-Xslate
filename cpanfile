requires 'Moo' => 1.006000;
requires 'Type::Tiny' => 1;
requires 'strictures' => 2;
requires 'namespace::clean' => 0;
requires 'Carp' => 0;

on test => sub {
    requires 'Test2::Bundle::Extended' => '0.000051';
};
